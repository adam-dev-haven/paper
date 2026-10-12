/**
 * Diagnostics.swift — the app working out what went wrong, by itself.
 *
 * When an analyst run fails, the useless version of this is a toast saying
 * "analysis failed" and the almost-as-useless version is asking a language model
 * why the language model did not answer. If the API is unreachable, out of credit,
 * rate limited, or returning refusals, the thing that cannot help you is another
 * request to it.
 *
 * Everything here is deterministic. It reads the run's own telemetry — HTTP
 * statuses, stop reasons, token counts, timings, error strings — and a handful of
 * facts about the machine, and produces findings in the shape that is actually
 * useful: **what was observed, what that means, and what to do about it.** No
 * model is consulted, nothing is spent, and it works precisely when the analyst
 * does not.
 *
 * The checks are ordered by how much they explain. A missing key explains every
 * downstream symptom, so it is reported alone rather than buried under six
 * consequences of itself.
 */

import Foundation

struct Finding: Codable, Identifiable {
    var id: String
    /// fault — this run cannot work until it is fixed.
    /// warning — it worked, but something is wrong or wasteful.
    /// note — worth knowing.
    /// ok — checked and healthy, stated so the absence of a fault is visible.
    var severity: String
    var title: String
    /// What the record actually shows. Numbers, not interpretation.
    var observed: String
    /// What that means.
    var meaning: String
    /// What to do. Empty only when there is nothing to do.
    var fix: String
    /// Whether simply running it again is likely to help.
    var retryHelps: Bool
}

struct Diagnosis: Codable {
    var at: Double
    var headline: String
    var findings: [Finding]
    var verdict: String
    var retryAdvised: Bool
    /// Present when the honest fix is a setting rather than an action.
    var suggestedBudgetTokens: Int?

    var faults: [Finding] { findings.filter { $0.severity == "fault" } }
}

enum Diagnostics {

    /* ------------------------------------------------------- the run post-mortem */

    /**
     * Explain a finished run from its own record.
     *
     * Called on every run, not only failed ones: a run that succeeded while paying
     * full price for a cache that should have been hit, or that truncated a pass and
     * silently dropped it, is a run worth a sentence.
     */
    static func diagnose(_ t: RunTelemetry, limits: RunLimits, keyPresent: Bool,
                         keySource: Credentials.Source) -> Diagnosis {
        var findings: [Finding] = []

        let statuses = t.calls.compactMap(\.httpStatus)
        let failed = t.calls.filter { !$0.ok }
        let errors = failed.compactMap(\.error)

        /* --- the one that explains everything else ------------------------------ */

        if !keyPresent {
            findings.append(Finding(
                id: "no-key", severity: "fault",
                title: "There is no API key for the analyst",
                observed: "No key was found in Paper's Keychain entry, or in ANTHROPIC_API_KEY.",
                meaning: "Every written pass needs one. Nothing was attempted, so nothing failed and nothing was spent. The ranking, levels, position sizes and refusals on the board are computed locally and do not involve the API.",
                fix: "Settings → Analyst → paste a key from console.anthropic.com. It is verified before it is saved and stored in your Keychain, never in a file.",
                retryHelps: false
            ))
            return assemble(t, findings, headline: "The analyst has no key", retryAdvised: false)
        }

        /* --- authentication and access ------------------------------------------ */

        if statuses.contains(401) {
            findings.append(Finding(
                id: "unauthorised", severity: "fault",
                title: "The API rejected the key",
                observed: "\(statuses.filter { $0 == 401 }.count) call\(statuses.filter { $0 == 401 }.count == 1 ? "" : "s") returned 401 Unauthorized. The key in use came from: \(keySource.label.lowercased()).",
                meaning: "The key exists but is not valid: mistyped, revoked, or belonging to a different account. Nothing was billed.",
                fix: "Settings → Analyst → Test the key. If it fails there too, generate a new one at console.anthropic.com and paste it in. \(keySource == .keychain ? "" : "A key saved in the app takes precedence over the one in use, so saving a valid one here resolves this without changing your environment.")",
                retryHelps: false
            ))
        }

        if statuses.contains(403) {
            findings.append(Finding(
                id: "forbidden", severity: "fault",
                title: "The key is valid but not allowed to use this model",
                observed: "\(statuses.filter { $0 == 403 }.count) call\(statuses.filter { $0 == 403 }.count == 1 ? "" : "s") returned 403 Forbidden against \(t.model).",
                meaning: "Authentication worked and authorisation did not. This usually means an account with no credit, or a model not enabled for that account.",
                fix: "Check the balance and model access at console.anthropic.com. If this model is not enabled, pick another under Settings → Analyst. Sonnet 5 is available to more accounts than Opus 5 and costs less.",
                retryHelps: false
            ))
        }

        if statuses.contains(404) {
            findings.append(Finding(
                id: "no-model", severity: "fault",
                title: "The model does not exist for this account",
                observed: "A call returned 404 for model \(t.model).",
                meaning: "The model name is wrong, or it is not available on this account.",
                fix: "Pick a different model under Settings → Analyst. If PAPER_MODEL is set in the environment and nothing is chosen in the app, that is what is being used.",
                retryHelps: false
            ))
        }

        /* --- transient upstream ------------------------------------------------- */

        if statuses.contains(429) {
            findings.append(Finding(
                id: "rate-limited", severity: "warning",
                title: "The account is rate limited",
                observed: "\(statuses.filter { $0 == 429 }.count) call\(statuses.filter { $0 == 429 }.count == 1 ? "" : "s") returned 429.",
                meaning: "Nothing is wrong with the key or the app. Requests are arriving faster than the account's tier allows; the screening pass runs its batches concurrently, which is the usual cause.",
                fix: "Wait a minute and run it again. If it keeps happening, lowering the token budget in Settings → Analyst reduces how many candidates go out at once.",
                retryHelps: true
            ))
        }

        let serverErrors = statuses.filter { $0 >= 500 }
        if !serverErrors.isEmpty {
            findings.append(Finding(
                id: "upstream", severity: "warning",
                title: "The API returned a server error",
                observed: "\(serverErrors.count) call\(serverErrors.count == 1 ? "" : "s") returned \(Set(serverErrors).sorted().map(String.init).joined(separator: ", ")).",
                meaning: "This is on Anthropic's side. A 529 means the service is temporarily overloaded.",
                fix: "Try again in a few minutes. Nothing needs changing.",
                retryHelps: true
            ))
        }

        let networkErrors = errors.filter {
            $0.contains("Could not reach") || $0.contains("offline") || $0.contains("timed out")
                || $0.contains("network connection") || $0.contains("hostname")
        }
        if !networkErrors.isEmpty {
            findings.append(Finding(
                id: "network", severity: "fault",
                title: "The API could not be reached",
                observed: "\(networkErrors.count) call\(networkErrors.count == 1 ? "" : "s") failed before getting a response — \(brief(networkErrors[0])).",
                meaning: "This is connectivity, not credentials. If the market data on the desk is also stale, the machine is offline. If prices are live, something is blocking api.anthropic.com specifically: a VPN, a proxy or a firewall.",
                fix: "Check the freshness badge in the top bar. Green means the network is fine and the block is specific to the API.",
                retryHelps: true
            ))
        }

        /* --- the model answered, and the answer was unusable --------------------- */

        let truncated = t.calls.filter { $0.stopReason == "max_tokens" }
        if !truncated.isEmpty {
            let passes = Set(truncated.map(\.pass)).sorted().joined(separator: ", ")
            findings.append(Finding(
                id: "truncated", severity: "fault",
                title: "A pass ran out of room mid-answer",
                observed: "\(truncated.count) call\(truncated.count == 1 ? "" : "s") stopped on max_tokens (\(passes)), having produced \(truncated.reduce(0) { $0 + $1.outputTokens }.formatted()) output tokens.",
                meaning: "The response was cut off partway through, so the JSON it was building was incomplete. The tokens were still billed. It presents as a parse error but the cause is a token ceiling set too low.",
                fix: "The ceiling for that pass is raised automatically on the next run. If it recurs, the cause is usually too many candidates at once; lowering the maximum open positions on the profile reduces how many are briefed.",
                retryHelps: true
            ))
        }

        let refusals = t.calls.filter { $0.stopReason == "refusal" }
        if !refusals.isEmpty {
            findings.append(Finding(
                id: "refusal", severity: "warning",
                title: "The model declined a request",
                observed: "\(refusals.count) call\(refusals.count == 1 ? "" : "s") came back with a refusal.",
                meaning: "A safety classifier stopped the response. In a market simulator this usually reflects the shape of the request: a pass asking for something that reads out of context as personalised financial advice.",
                fix: "The other passes still stand. If it repeats on the same pass every time, that pass has a prompt problem; report it rather than retrying.",
                retryHelps: false
            ))
        }

        let invalid = errors.filter { $0.contains("could not validate") || $0.contains("decode") }
        if !invalid.isEmpty && truncated.isEmpty {
            findings.append(Finding(
                id: "schema", severity: "warning",
                title: "A pass returned JSON that did not match its schema",
                observed: "\(invalid.count) response\(invalid.count == 1 ? "" : "s") failed validation.",
                meaning: "Structured outputs guarantee the shape, so this normally means the response was empty or cut short rather than malformed. Responses are validated on arrival, which is why it surfaces here rather than later.",
                fix: "Running it again usually clears it. If the same pass fails this way twice, the governor stops the run rather than paying for a third attempt.",
                retryHelps: true
            ))
        }

        /* --- why the governor stepped in ---------------------------------------- */

        if let cause = t.stoppedBy {
            let byPass = Dictionary(grouping: t.calls, by: \.pass)
                .map { (pass: $0.key, tokens: $0.value.reduce(0) { $0 + $1.billedTokens }) }
                .sorted { $0.tokens > $1.tokens }
            let breakdown = byPass.prefix(3)
                .map { "\($0.pass) \($0.tokens.formatted())" }
                .joined(separator: ", ")

            switch cause {
            case .budget:
                findings.append(Finding(
                    id: "budget", severity: "warning",
                    title: "The run stopped at its token budget",
                    observed: "\(t.billedTokens.formatted()) of \(limits.budgetTokens.formatted()) tokens across \(t.calls.count) calls. Heaviest: \(breakdown).",
                    meaning: "The budget stopped the run; this is not a fault. Everything produced before the ceiling is kept, since the passes are chained and an earlier one stands without the later ones.",
                    fix: "Raise the budget in Settings → Analyst if the run should finish. The engine's own ranking, levels and sizing do not depend on the skipped passes.",
                    retryHelps: false
                ))
            case .wallClock:
                findings.append(Finding(
                    id: "slow", severity: "warning",
                    title: "The run passed its time limit",
                    observed: "\(Int((t.finishedAt > 0 ? t.finishedAt - t.startedAt : nowMs() - t.startedAt) / 1000))s elapsed against a \(Int(limits.wallClockSeconds))s ceiling, over \(t.calls.count) calls.",
                    meaning: "Either the API is unusually slow, or a socket hung. The ceiling exists because a hung request spends no tokens and still holds the run open.",
                    fix: "Try again. If it happens repeatedly at the same pass, that pass is being asked for too much at once.",
                    retryHelps: true
                ))
            case .repeatFailure:
                findings.append(Finding(
                    id: "loop", severity: "fault",
                    title: "The same failure repeated, so the run was stopped",
                    observed: t.stopNote ?? "A pass failed identically twice.",
                    meaning: "A failure that repeats byte for byte is deterministic, so the same request will produce it again. Retrying would spend the budget confirming that.",
                    fix: "The findings above name the underlying cause. Fix that rather than re-running.",
                    retryHelps: false
                ))
            case .noProgress:
                findings.append(Finding(
                    id: "no-progress", severity: "fault",
                    title: "Calls were completing and returning nothing",
                    observed: t.stopNote ?? "Several calls in a row returned nothing usable.",
                    meaning: "The requests succeed, the tokens are billed, and nothing usable comes back. Left running it spends the whole budget and reports an empty analysis.",
                    fix: "The cause is usually truncation or a refusal; check the findings above. If neither is present, report it as a bug.",
                    retryHelps: false
                ))
            case .failureStreak:
                findings.append(Finding(
                    id: "streak", severity: "fault",
                    title: "Too many calls failed in a row",
                    observed: t.stopNote ?? "Several consecutive failures.",
                    meaning: "The problem is upstream of any single pass: credentials, connectivity, or the account.",
                    fix: "The findings above should name it. If none of them do, run the checks under Settings → Analyst.",
                    retryHelps: false
                ))
            case .cancelled:
                findings.append(Finding(
                    id: "cancelled", severity: "note",
                    title: "You stopped the run",
                    observed: "\(t.billedTokens.formatted()) tokens were billed before it stopped.",
                    meaning: "Calls already in flight when stop was pressed still complete and are still billed.",
                    fix: "", retryHelps: true
                ))
            }
        }

        /* --- efficiency, which is a fault of its own kind ------------------------ */

        /* The cache only ever shares *within* a pass — every pass carries a different
         * output schema, so the prefix is matched from the start of the request and
         * two passes never hit each other's entry. A run where each pass made exactly
         * one call therefore reads nothing back, and that is correct rather than
         * broken.
         *
         * The fault is a pass that called more than once and still read nothing, which
         * means the calls started simultaneously and each paid the write price — worse
         * than not caching at all, since a write costs a quarter more than plain text. */
        let repeatedPass = Dictionary(grouping: t.calls, by: \.pass).values.contains { $0.count > 1 }
        if repeatedPass, t.cacheReadTokens == 0, t.cacheWriteTokens > 0 {
            findings.append(Finding(
                id: "cache-cold", severity: "warning",
                title: "The prompt cache was written repeatedly and never read",
                observed: "A pass ran more than once, and across \(t.calls.count) calls the run wrote \(t.cacheWriteTokens.formatted()) tokens to the cache and read \(t.cacheReadTokens.formatted()) back.",
                meaning: "Repeated calls within a pass send the same instructions ahead of their own content, marked cacheable so the prefix is billed once rather than once per call. Writing it repeatedly without reading it costs a quarter more than sending the tokens plain. The usual cause is calls starting simultaneously, before any has written the entry the others would read.",
                fix: "This is a fault in Paper rather than in your setup, and worth reporting. It costs money rather than breaking anything.",
                retryHelps: false
            ))
        }

        if findings.isEmpty || findings.allSatisfy({ $0.severity == "note" }) {
            let hit = t.cacheHitRate.map { " \(f($0, 0))% of the input was served from cache." } ?? ""
            findings.append(Finding(
                id: "healthy", severity: "ok",
                title: "The run completed cleanly",
                observed: "\(t.calls.count) calls, \(t.billedTokens.formatted()) tokens, \(Int((t.finishedAt - t.startedAt) / 1000))s.\(hit)",
                meaning: "Nothing needed explaining.",
                fix: "", retryHelps: false
            ))
        }

        let severity = findings.contains { $0.severity == "fault" } ? "fault"
            : findings.contains { $0.severity == "warning" } ? "warning" : "ok"
        let headline: String
        switch severity {
        case "fault": headline = findings.first { $0.severity == "fault" }!.title
        case "warning": headline = findings.first { $0.severity == "warning" }!.title
        default: headline = "The analyst is working normally"
        }

        return assemble(t, findings, headline: headline,
                        retryAdvised: findings.contains { $0.retryHelps } && !findings.contains { $0.severity == "fault" && !$0.retryHelps })
    }

    private static func assemble(_ t: RunTelemetry, _ findings: [Finding],
                                 headline: String, retryAdvised: Bool) -> Diagnosis {
        let spent = t.billedTokens
        let cost = t.estimatedCost.map { " — about $\(f($0, 2)) at this model's published rates" } ?? ""
        var verdict = "\(t.calls.count) call\(t.calls.count == 1 ? "" : "s") to \(t.model), \(spent.formatted()) tokens billed\(cost)."
        if t.failures > 0 { verdict += " \(t.failures) of them failed." }
        if t.stoppedBy == .budget {
            verdict += " The budget was the binding constraint rather than a failure. The passes that had already"
                + " run are kept, and raising the budget is a choice about what an analysis is worth."
        } else if retryAdvised {
            verdict += " Running it again is worth trying; the causes above often clear on their own."
        } else if findings.contains(where: { $0.severity == "fault" }) {
            verdict += " Running it again will produce the same result until the fault above is dealt with."
        } else {
            verdict += " Nothing here needs action."
        }

        var suggested: Int?
        if t.stoppedBy == .budget { suggested = Swift.min(t.budgetTokens * 2, 2_000_000) }

        return Diagnosis(at: nowMs(), headline: headline, findings: findings,
                         verdict: verdict, retryAdvised: retryAdvised,
                         suggestedBudgetTokens: suggested)
    }

    /* ---------------------------------------------------- the standing checks */

    /**
     * What can be checked at rest, without a run and without spending anything.
     *
     * This is what the "Check the setup" button does. Everything here is free: no
     * request is made to the API, because the point of the button is to work when
     * the API is the thing that is broken.
     */
    static func selfCheck(dataDirectory: URL, model: String,
                          lastRun: RunTelemetry?, marketFresh: Bool,
                          marketAgeSeconds: Int?) -> Diagnosis {
        var findings: [Finding] = []

        // --- credentials
        let status = Credentials.status()
        findings.append(Finding(
            id: "key", severity: status.hasKey ? "ok" : "warning",
            title: status.hasKey ? "An API key is present" : "No API key is set",
            observed: status.hasKey
                ? "\(status.sourceLabel), \(status.fingerprint ?? "").".replacingOccurrences(of: " ,", with: ",")
                : "Nothing in the Keychain or in ANTHROPIC_API_KEY.",
            meaning: status.hasKey
                ? "Present is not the same as working. Use Test the key to make one real request and find out."
                : "The written analysis is off. Every number on the board is still computed here and is unaffected.",
            fix: status.hasKey ? "" : "Settings → Analyst → paste a key.",
            retryHelps: false
        ))

        // --- is the model one we can price
        findings.append(Finding(
            id: "model", severity: ModelPrice.of(model) == nil ? "note" : "ok",
            title: ModelPrice.of(model) == nil ? "The model in use has no published rate here" : "The model is known and priced",
            observed: "Using \(model), from \(AnalystModel.source)." + (AnalystModel.currentFast.map { " Screening and the trade notes run on \($0)." } ?? ""),
            meaning: ModelPrice.of(model) == nil
                ? "Token counts will still be exact; the cost estimate will be blank rather than guessed, because a wrong number there is worse than none."
                : "Token counts and cost estimates are both available.",
            fix: "", retryHelps: false
        ))

        // --- the network, tested through the free feed rather than the paid one
        findings.append(Finding(
            id: "market", severity: marketFresh ? "ok" : "warning",
            title: marketFresh ? "Market data is arriving" : "Market data is stale",
            observed: marketAgeSeconds.map { "The newest quote is \($0)s old." } ?? "No quote has arrived yet.",
            meaning: marketFresh
                ? "The machine is online. If the analyst cannot reach its API while this is green, something is blocking api.anthropic.com specifically rather than the network as a whole."
                : "Either the machine is offline or the price feed is refusing requests. The analyst will fail for the same reason until it clears.",
            fix: marketFresh ? "" : "Press Refresh in the top bar. If the badge stays red, check the connection.",
            retryHelps: !marketFresh
        ))

        // --- can we actually write the ledgers
        let writable = FileManager.default.isWritableFile(atPath: dataDirectory.path)
            || (try? FileManager.default.createDirectory(at: dataDirectory, withIntermediateDirectories: true)) != nil
        findings.append(Finding(
            id: "storage", severity: writable ? "ok" : "fault",
            title: writable ? "The data directory is writable" : "The data directory cannot be written to",
            observed: dataDirectory.path,
            meaning: writable
                ? "Ledgers, profiles and what the engine has learned are all saved here."
                : "Trades, profile edits and lessons will appear to work and be lost on relaunch.",
            fix: writable ? "" : "Check the permissions on that folder.",
            retryHelps: false
        ))

        // --- what the last run says
        if let last = lastRun {
            let ago = Int((nowMs() - last.startedAt) / 60_000)
            findings.append(Finding(
                id: "last-run", severity: last.stoppedBy == nil && last.failures == 0 ? "ok" : "note",
                title: "The last run, \(ago)m ago",
                observed: "\(last.kind): \(last.calls.count) calls, \(last.billedTokens.formatted()) tokens, \(last.failures) failed."
                    + (last.stoppedBy.map { " Stopped by: \($0.rawValue)." } ?? ""),
                meaning: last.diagnosis?.headline ?? "Completed without the governor stepping in.",
                fix: "", retryHelps: false
            ))
        } else {
            findings.append(Finding(
                id: "last-run", severity: "note",
                title: "No analyst run on record yet",
                observed: "Nothing to read.",
                meaning: "The token accounting fills in once an analysis has run.",
                fix: "", retryHelps: false
            ))
        }

        let faults = findings.filter { $0.severity == "fault" }
        let warnings = findings.filter { $0.severity == "warning" }
        let headline = faults.first?.title ?? warnings.first?.title ?? "Everything checks out"
        let verdict = faults.isEmpty && warnings.isEmpty
            ? "Every check passed. None of these required a request to the API; they run locally so they still work when the analyst does not."
            : "\(faults.count + warnings.count) of \(findings.count) checks want attention. None of this required a request to the API."

        return Diagnosis(at: nowMs(), headline: headline, findings: findings,
                         verdict: verdict, retryAdvised: false, suggestedBudgetTokens: nil)
    }

    private static func brief(_ s: String) -> String {
        s.count > 120 ? String(s.prefix(117)) + "…" : s
    }
}
