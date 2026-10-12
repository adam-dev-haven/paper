/**
 * Budget.swift — what a run is allowed to spend, and what it actually spent.
 *
 * The analyst is six chained passes over a dozen instruments, some of them at high
 * effort. That is the right shape for the job and it is also the shape of a bill
 * nobody sees coming, on somebody else's API key. Worse, a pipeline with retries
 * in it has a failure mode where nothing is obviously broken and tokens leave
 * anyway: a pass that returns unparseable output, gets retried, returns
 * unparseable output, gets retried.
 *
 * So every call goes through a governor that is asked *before* it runs and told
 * *after* it finishes:
 *
 *   - A hard token budget per run, checked before each call. Exceed it and the run
 *     stops with partial results rather than continuing into the dark.
 *   - A wall-clock ceiling, because a hung socket spends no tokens and still ruins
 *     an afternoon.
 *   - Attempt caps per pass and a consecutive-failure cap across the run.
 *   - A repeat detector: the same error, or the same unusable output, twice in a
 *     row is a loop, not bad luck.
 *
 * Everything a call did is recorded — tokens in and out, cache reads and writes,
 * milliseconds, stop reason, HTTP status, error. That record is what makes the
 * next file, Diagnostics.swift, able to say what went wrong without asking a model
 * to guess. An app that needs an AI to explain why its AI failed has built the
 * problem twice.
 */

import Foundation

/* ------------------------------------------------------------------ pricing */

/// Published per-million-token rates. Held as data rather than folded into a
/// formula so a model change is one line, and so a model nobody priced here
/// reports "unpriced" instead of a confidently wrong number.
struct ModelPrice {
    let inputPerMTok: Double
    let outputPerMTok: Double

    /// Cache reads bill at a tenth of the input rate; writing to the cache costs a
    /// quarter more than the same tokens uncached.
    var cacheReadPerMTok: Double { inputPerMTok * 0.1 }
    var cacheWritePerMTok: Double { inputPerMTok * 1.25 }

    static let table: [String: ModelPrice] = [
        "claude-opus-5":     ModelPrice(inputPerMTok: 5, outputPerMTok: 25),
        "claude-opus-4-8":   ModelPrice(inputPerMTok: 5, outputPerMTok: 25),
        "claude-opus-4-7":   ModelPrice(inputPerMTok: 5, outputPerMTok: 25),
        "claude-sonnet-5":   ModelPrice(inputPerMTok: 2, outputPerMTok: 10),
        "claude-haiku-4-5":  ModelPrice(inputPerMTok: 1, outputPerMTok: 5),
        "claude-fable-5-1":  ModelPrice(inputPerMTok: 10, outputPerMTok: 50),
    ]

    static func of(_ model: String) -> ModelPrice? { table[model] }
}

/* -------------------------------------------------------------- the record */

/// One request to the API, as it actually happened.
struct CallRecord: Codable, Identifiable {
    var id: String = UUID().uuidString
    /// screen | rank | brief | review | report | learn | explain | check
    var pass: String
    /// Recorded per call, not per run: a mechanical pass may go to a cheaper model
    /// than the one doing the judgement, and a run priced at a single rate would be
    /// wrong in whichever direction the mix leaned.
    var model: String = ""
    var attempt: Int
    var startedAt: Double
    var ms: Double

    var inputTokens: Int
    var outputTokens: Int
    var cacheReadTokens: Int
    var cacheWriteTokens: Int

    var stopReason: String?
    var httpStatus: Int?
    var error: String?
    var ok: Bool

    /// Everything billed, for a single number in the interface.
    var billedTokens: Int { inputTokens + outputTokens + cacheReadTokens + cacheWriteTokens }

    /// Priced at this call's own model, falling back to the run's where a record
    /// predates per-call models.
    func cost(_ fallback: ModelPrice?) -> Double? {
        guard let p = ModelPrice.of(model) ?? fallback else { return nil }
        return Double(inputTokens) / 1_000_000 * p.inputPerMTok
            + Double(outputTokens) / 1_000_000 * p.outputPerMTok
            + Double(cacheReadTokens) / 1_000_000 * p.cacheReadPerMTok
            + Double(cacheWriteTokens) / 1_000_000 * p.cacheWritePerMTok
    }
}

/// Why a run stopped early, when it did.
enum StopCause: String, Codable {
    case budget          // the token ceiling
    case wallClock       // the time ceiling
    case repeatFailure   // the same failure twice
    case noProgress      // calls completing, nothing usable coming back
    case failureStreak   // too many failures of any kind in a row
    case cancelled       // the user pressed stop

    var headline: String {
        switch self {
        case .budget: return "Stopped at the token budget"
        case .wallClock: return "Stopped at the time limit"
        case .repeatFailure: return "Stopped: the same failure kept repeating"
        case .noProgress: return "Stopped: calls completed but returned nothing usable"
        case .failureStreak: return "Stopped after too many failures in a row"
        case .cancelled: return "Stopped by you"
        }
    }
}

/// The whole accounting for one analyst run.
struct RunTelemetry: Codable {
    var runId: String
    /// ideas | review | explain | check
    var kind: String
    var model: String
    var startedAt: Double
    var finishedAt: Double
    var budgetTokens: Int
    var calls: [CallRecord]
    var stoppedBy: StopCause?
    var stopNote: String?
    /// Filled in by Diagnostics when a run ends badly. Deterministic, no model involved.
    var diagnosis: Diagnosis?

    var inputTokens: Int { calls.reduce(0) { $0 + $1.inputTokens } }
    var outputTokens: Int { calls.reduce(0) { $0 + $1.outputTokens } }
    var cacheReadTokens: Int { calls.reduce(0) { $0 + $1.cacheReadTokens } }
    var cacheWriteTokens: Int { calls.reduce(0) { $0 + $1.cacheWriteTokens } }
    var billedTokens: Int { calls.reduce(0) { $0 + $1.billedTokens } }
    var failures: Int { calls.filter { !$0.ok }.count }

    /**
     * Summed per call at each call's own model, so a run that screened on Sonnet and
     * ranked on Opus is priced as what it was rather than as either one of them.
     *
     * Nil only when nothing in the run could be priced at all — a wrong number here
     * is worse than a blank, since it is the figure someone sets a budget against.
     */
    var estimatedCost: Double? {
        let fallback = ModelPrice.of(model)
        let priced = calls.compactMap { $0.cost(fallback) }
        return priced.isEmpty ? nil : priced.reduce(0, +)
    }

    /// Every model this run actually used, for the receipt to name.
    var modelsUsed: [String] {
        var seen: [String] = []
        for call in calls where !call.model.isEmpty && !seen.contains(call.model) {
            seen.append(call.model)
        }
        return seen.isEmpty ? [model] : seen
    }

    /**
     * How much of the repeated input was served from cache.
     *
     * Worth reading with a caveat that measurement forced into this comment rather
     * than assumption: the cached prefix is matched from the start of the request,
     * and each pass sends a different output schema, so **passes do not share a cache
     * entry with each other**. What does share is repeated calls *within* a pass —
     * the screen batches — which is why the first of those runs alone to warm it.
     *
     * A run of six passes therefore tops out at a modest hit rate by construction.
     * Zero, with writes happening, is the thing that is actually wrong.
     */
    var cacheHitRate: Double? {
        let repeated = cacheReadTokens + cacheWriteTokens
        guard repeated > 0 || inputTokens > 0 else { return nil }
        let denominator = Double(inputTokens + repeated)
        guard denominator > 0 else { return nil }
        return Double(cacheReadTokens) / denominator * 100
    }

    static func empty(kind: String, model: String, budget: Int) -> RunTelemetry {
        RunTelemetry(runId: UUID().uuidString, kind: kind, model: model,
                     startedAt: nowMs(), finishedAt: 0, budgetTokens: budget,
                     calls: [], stoppedBy: nil, stopNote: nil, diagnosis: nil)
    }

    /* ------------------------------------------------------------------ coding */

    /**
     * Encoded explicitly, because the interesting numbers here are computed.
     *
     * Swift's synthesised Codable writes stored properties only, so `estimatedCost`
     * and the token totals crossed the wire as nothing at all — the receipt had a
     * cost column that was always blank and no way to notice, since a missing field
     * and a genuinely unpriced model look identical to the page. Anything the
     * interface reads is written here on purpose.
     */
    enum CodingKeys: String, CodingKey {
        case runId, kind, model, startedAt, finishedAt, budgetTokens, calls
        case stoppedBy, stopNote, diagnosis
        // Derived, written for the interface, ignored on the way back in.
        case inputTokens, outputTokens, cacheReadTokens, cacheWriteTokens
        case billedTokens, failures, estimatedCost, cacheHitRate, modelsUsed
    }

    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(runId, forKey: .runId)
        try c.encode(kind, forKey: .kind)
        try c.encode(model, forKey: .model)
        try c.encode(startedAt, forKey: .startedAt)
        try c.encode(finishedAt, forKey: .finishedAt)
        try c.encode(budgetTokens, forKey: .budgetTokens)
        try c.encode(calls, forKey: .calls)
        try c.encodeIfPresent(stoppedBy, forKey: .stoppedBy)
        try c.encodeIfPresent(stopNote, forKey: .stopNote)
        try c.encodeIfPresent(diagnosis, forKey: .diagnosis)

        try c.encode(inputTokens, forKey: .inputTokens)
        try c.encode(outputTokens, forKey: .outputTokens)
        try c.encode(cacheReadTokens, forKey: .cacheReadTokens)
        try c.encode(cacheWriteTokens, forKey: .cacheWriteTokens)
        try c.encode(billedTokens, forKey: .billedTokens)
        try c.encode(failures, forKey: .failures)
        try c.encodeIfPresent(estimatedCost, forKey: .estimatedCost)
        try c.encodeIfPresent(cacheHitRate, forKey: .cacheHitRate)
        try c.encode(modelsUsed, forKey: .modelsUsed)
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        runId = try c.decodeIfPresent(String.self, forKey: .runId) ?? UUID().uuidString
        kind = try c.decodeIfPresent(String.self, forKey: .kind) ?? "ideas"
        model = try c.decodeIfPresent(String.self, forKey: .model) ?? ""
        startedAt = try c.decodeIfPresent(Double.self, forKey: .startedAt) ?? 0
        finishedAt = try c.decodeIfPresent(Double.self, forKey: .finishedAt) ?? 0
        budgetTokens = try c.decodeIfPresent(Int.self, forKey: .budgetTokens) ?? 0
        calls = try c.decodeIfPresent([CallRecord].self, forKey: .calls) ?? []
        stoppedBy = try c.decodeIfPresent(StopCause.self, forKey: .stoppedBy)
        stopNote = try c.decodeIfPresent(String.self, forKey: .stopNote)
        diagnosis = try c.decodeIfPresent(Diagnosis.self, forKey: .diagnosis)
        // The derived keys are deliberately not read back — they are recomputed from
        // `calls`, so a hand-edited file cannot state a cost the calls do not support.
    }

    init(runId: String, kind: String, model: String, startedAt: Double, finishedAt: Double,
         budgetTokens: Int, calls: [CallRecord], stoppedBy: StopCause?, stopNote: String?,
         diagnosis: Diagnosis?) {
        self.runId = runId; self.kind = kind; self.model = model
        self.startedAt = startedAt; self.finishedAt = finishedAt
        self.budgetTokens = budgetTokens; self.calls = calls
        self.stoppedBy = stoppedBy; self.stopNote = stopNote; self.diagnosis = diagnosis
    }
}

/* ---------------------------------------------------------------- the limits */

struct RunLimits: Codable {
    /// Everything one run may bill, across every pass.
    var budgetTokens: Int
    /// Wall clock, in seconds.
    var wallClockSeconds: Double
    /// Attempts allowed for any one pass before it is abandoned.
    var attemptsPerPass: Int
    /// Failures in a row, across the run, before the whole thing stops.
    var failureStreak: Int
    /// Calls that may complete with nothing usable before the run is called stuck.
    var emptyStreak: Int

    static let standard = RunLimits(
        budgetTokens: 400_000, wallClockSeconds: 600,
        attemptsPerPass: 2, failureStreak: 3, emptyStreak: 3
    )

    /// For someone watching the meter, or testing.
    static let frugal = RunLimits(
        budgetTokens: 120_000, wallClockSeconds: 300,
        attemptsPerPass: 1, failureStreak: 2, emptyStreak: 2
    )

    init(budgetTokens: Int, wallClockSeconds: Double, attemptsPerPass: Int,
         failureStreak: Int, emptyStreak: Int) {
        self.budgetTokens = budgetTokens
        self.wallClockSeconds = wallClockSeconds
        self.attemptsPerPass = attemptsPerPass
        self.failureStreak = failureStreak
        self.emptyStreak = emptyStreak
    }

    /// Tolerant of an older settings file that predates a field.
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let d = RunLimits.standard
        budgetTokens = try c.decodeIfPresent(Int.self, forKey: .budgetTokens) ?? d.budgetTokens
        wallClockSeconds = try c.decodeIfPresent(Double.self, forKey: .wallClockSeconds) ?? d.wallClockSeconds
        attemptsPerPass = try c.decodeIfPresent(Int.self, forKey: .attemptsPerPass) ?? d.attemptsPerPass
        failureStreak = try c.decodeIfPresent(Int.self, forKey: .failureStreak) ?? d.failureStreak
        emptyStreak = try c.decodeIfPresent(Int.self, forKey: .emptyStreak) ?? d.emptyStreak
    }

    /// Clamped on the way in, so a typed-in zero cannot disable the governor.
    func sanitised() -> RunLimits {
        RunLimits(
            budgetTokens: Swift.max(20_000, Swift.min(budgetTokens, 5_000_000)),
            wallClockSeconds: Swift.max(60, Swift.min(wallClockSeconds, 3_600)),
            attemptsPerPass: Swift.max(1, Swift.min(attemptsPerPass, 4)),
            failureStreak: Swift.max(1, Swift.min(failureStreak, 8)),
            emptyStreak: Swift.max(1, Swift.min(emptyStreak, 8))
        )
    }
}

/* -------------------------------------------------------------- the governor */

/**
 * Asked before every call, told after every one.
 *
 * An actor because the screen pass runs its batches concurrently, and a budget
 * that four tasks can each read as "still fine" before any of them writes is not a
 * budget.
 */
actor Governor {

    enum Permit {
        /// Carries the reservation this call was granted. Hand it back to `record`
        /// or `recordEmpty` so the budget it is holding is released.
        case go(ticket: String)
        case stop(StopCause, String)
    }

    private(set) var telemetry: RunTelemetry
    private let limits: RunLimits

    /**
     * Calls of a pass that have come back with nothing usable.
     *
     * Counted on failure rather than on permission, which is the distinction the
     * old `attempts` counter missed. `attemptsPerPass` means "stop retrying a pass
     * that keeps failing"; incrementing it every time a call was *allowed* turned
     * it into a cap on concurrency instead. The screen pass fans out one batch per
     * four candidates, so at the standard limit of two the third batch was refused
     * before it ran — not because anything had failed, but because two other
     * batches were already in flight. On a board of a dozen candidates that
     * silently dropped a third of the screening.
     */
    private var failures: [String: Int] = [:]
    /**
     * Tokens promised to calls that have been permitted and have not reported back.
     *
     * Being an actor made the *check* atomic and left the budget itself unguarded,
     * which is a different thing. The screen pass fans four batches out at once;
     * each one asked permission, each was answered in turn from a `billedTokens`
     * that none of the others had yet moved, and all four were waved through a
     * budget only two of them fitted in. Measured: a 50,000-token budget permitted
     * four calls estimated at 25,000 each.
     *
     * So a permit now *reserves* its estimate, and the reservation is released when
     * the call reports what it actually cost. The budget is the sum of what has
     * been billed and what has been promised, which is the only figure a
     * concurrent caller can safely reason about.
     */
    private var reserved: [String: Int] = [:]
    private var consecutiveFailures = 0
    private var consecutiveEmpties = 0
    /// The last failure text per pass, to notice the same one arriving twice.
    private var lastFailure: [String: String] = [:]
    private var cancelled = false

    init(kind: String, model: String, limits: RunLimits) {
        self.limits = limits.sanitised()
        self.telemetry = .empty(kind: kind, model: model, budget: self.limits.budgetTokens)
    }

    var stopped: StopCause? { telemetry.stoppedBy }
    var spent: Int { telemetry.billedTokens }
    /// What is left after both what has been billed and what is promised to calls
    /// already in flight.
    var remaining: Int { Swift.max(0, limits.budgetTokens - committed) }

    private var committed: Int { telemetry.billedTokens + reserved.values.reduce(0, +) }

    /// Hands back a reservation once the call it was made for has reported.
    private func release(_ id: String) { reserved.removeValue(forKey: id) }

    func cancel() {
        cancelled = true
        trip(.cancelled, "The run was stopped from the interface.")
    }

    private func trip(_ cause: StopCause, _ note: String) {
        guard telemetry.stoppedBy == nil else { return }
        telemetry.stoppedBy = cause
        telemetry.stopNote = note
        log("[governor] \(cause.rawValue): \(note)")
    }

    /**
     * May this call go ahead?
     *
     * Deliberately conservative about the budget: a pass is not started unless
     * enough of the budget remains to plausibly finish it, because a call that is
     * killed halfway is billed in full and produces nothing.
     */
    func permit(pass: String, estimatedTokens: Int) -> Permit {
        if let cause = telemetry.stoppedBy {
            return .stop(cause, telemetry.stopNote ?? cause.headline)
        }
        if cancelled { return .stop(.cancelled, "Stopped from the interface.") }

        // Checked before the budget, so a pass that has already given up does not
        // reserve anything on its way out.
        let failed = failures[pass] ?? 0
        if failed >= limits.attemptsPerPass {
            // Not a run-level stop: one pass giving up degrades to partial results.
            return .stop(.repeatFailure, "The \(pass) pass failed \(failed) times without a usable result, so it was abandoned. The passes before it still stand.")
        }

        let elapsed = (nowMs() - telemetry.startedAt) / 1000
        if elapsed > limits.wallClockSeconds {
            let note = "The run passed its \(Int(limits.wallClockSeconds))-second ceiling with \(telemetry.calls.count) calls made. Whatever is slow is slow in a way that retrying will not fix, so the run stopped rather than holding a socket open indefinitely."
            trip(.wallClock, note)
            return .stop(.wallClock, note)
        }

        // Against everything committed, not just everything billed — see `reserved`.
        let used = committed
        if used + estimatedTokens > limits.budgetTokens {
            let note = used >= limits.budgetTokens
                ? "The run reached its \(grouped(limits.budgetTokens)) token budget. Everything produced before that point is kept; the remaining passes did not run."
                : "The next pass was expected to need about \(grouped(estimatedTokens)) tokens and only \(grouped(remaining)) of the \(grouped(limits.budgetTokens)) budget was left. Starting it would have spent the remainder and produced nothing, since a call cut off midway is billed in full and returns nothing usable."
            trip(.budget, note)
            return .stop(.budget, note)
        }

        ticketSeq += 1
        let ticket = "\(pass)#\(ticketSeq)"
        reserved[ticket] = estimatedTokens
        return .go(ticket: ticket)
    }

    private var ticketSeq = 0

    /// Records what a call did and re-checks the loop detectors.
    func record(_ call: CallRecord, ticket: String? = nil) {
        if let ticket { release(ticket) }
        telemetry.calls.append(call)

        if call.ok {
            consecutiveFailures = 0
            consecutiveEmpties = 0
            lastFailure[call.pass] = nil
            return
        }

        consecutiveFailures += 1
        failures[call.pass] = (failures[call.pass] ?? 0) + 1
        if let error = call.error {
            // The same message twice in a row from the same pass is a loop. Retrying a
            // deterministic failure is how a pipeline spends a budget on nothing.
            if lastFailure[call.pass] == error {
                trip(.repeatFailure, "The \(call.pass) pass failed twice with the same error: \(short(error)). A failure that repeats identically is deterministic, so the run stopped rather than paying for a third attempt.")
            }
            lastFailure[call.pass] = error
        }

        if consecutiveFailures >= limits.failureStreak {
            trip(.failureStreak, "\(consecutiveFailures) calls failed in a row. Something is wrong upstream of the request rather than with any one pass.")
        }
    }

    /// A call that succeeded at the HTTP level and returned nothing usable. Counted
    /// separately, because it is the quiet failure — the one that costs money and
    /// looks like progress.
    func recordEmpty(_ call: CallRecord, reason: String, ticket: String? = nil) {
        if let ticket { release(ticket) }
        telemetry.calls.append(call)
        consecutiveEmpties += 1
        failures[call.pass] = (failures[call.pass] ?? 0) + 1
        if consecutiveEmpties >= limits.emptyStreak {
            trip(.noProgress, "\(consecutiveEmpties) calls in a row completed and returned nothing usable (\(short(reason))). Tokens are being spent without anything coming back, which is the failure worth stopping for.")
        }
    }

    func finish(diagnosis: Diagnosis?) -> RunTelemetry {
        telemetry.finishedAt = nowMs()
        telemetry.diagnosis = diagnosis
        return telemetry
    }

    private func short(_ s: String) -> String {
        s.count > 160 ? String(s.prefix(157)) + "…" : s
    }
}

/**
 * Grouping separators for the governor's own sentences.
 *
 * A free function rather than `extension Int { func formatted() }`, which is what
 * this was. That signature is identical to the standard library's `Int.formatted()`
 * and, being declared in this module, silently won out at every call site in the
 * app — including any that wanted the locale-aware one. An extension on a standard
 * type, with a standard name, is a trap laid for whoever writes the next call.
 *
 * Built by hand rather than with `NumberFormatter`, which allocated on every call
 * and was being asked for a fixed comma anyway. The separator is deliberately not
 * localised: these strings sit inside English prose written in the same breath.
 */
func grouped(_ value: Int) -> String {
    let digits = String(abs(value))
    var out = ""
    for (i, c) in digits.enumerated() {
        if i > 0, (digits.count - i) % 3 == 0 { out.append(",") }
        out.append(c)
    }
    return (value < 0 ? "-" : "") + out
}
