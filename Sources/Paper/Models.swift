/**
 * Models.swift — which model does which pass, and what that costs.
 *
 * The analyst was hardcoded to Opus 5 with an environment variable as the only way
 * out, which is fine for the machine it was built on and useless to anyone else.
 * It also flattened something worth not flattening: **the six passes are not the
 * same job.**
 *
 *   Screening reads a metric pack and three headlines and emits structured JSON.
 *   It is mechanical. It runs at `low` effort already because depth buys nothing
 *   there, and it is the pass that runs most often — four batches per analysis
 *   against one call each for ranking and briefing.
 *
 *   Ranking a basket against a person's circumstances, and writing the brief that
 *   has to teach someone why a stop belongs where it is, are judgement. That is
 *   where the capable model earns its rate.
 *
 * So there are two settings rather than one: the model that thinks, and an
 * optional cheaper one for the mechanical passes. Both default to the most capable
 * option — downgrading for cost is the user's decision to make deliberately, not
 * one this app should make on their behalf and not mention.
 *
 * The catalogue is data because the request shape is not uniform. Haiku 4.5 takes
 * a thinking budget and rejects `effort`; the current Opus and Sonnet models take
 * adaptive thinking and an effort level. Shipping a picker where one option
 * returns a 400 would be worse than not shipping the picker.
 */

import Foundation

struct ModelOption: Codable, Identifiable {
    var id: String { modelId }
    let modelId: String
    let name: String
    let inputPerMTok: Double
    let outputPerMTok: Double
    /// `effort` is rejected by some models; where it is, depth is set by a thinking
    /// budget instead.
    let supportsEffort: Bool
    /// True where thinking is configured as `{type: "adaptive"}`; false where it
    /// takes an explicit `budget_tokens`.
    let adaptiveThinking: Bool
    /// What this model is actually for, in this app.
    let note: String
    /// False for models that should not be asked to write the teaching brief.
    let suitableForJudgement: Bool

    /// Relative to the default, for the interface to state plainly.
    func costVersus(_ other: ModelOption) -> Double {
        guard other.inputPerMTok > 0 else { return 1 }
        // Weighted the way these runs actually bill: roughly four parts input to one
        // part output.
        let mine = inputPerMTok * 0.8 + outputPerMTok * 0.2
        let theirs = other.inputPerMTok * 0.8 + other.outputPerMTok * 0.2
        return theirs > 0 ? mine / theirs : 1
    }
}

enum ModelCatalogue {

    static let all: [ModelOption] = [
        ModelOption(
            modelId: "claude-opus-5", name: "Opus 5",
            inputPerMTok: 5, outputPerMTok: 25,
            supportsEffort: true, adaptiveThinking: true,
            note: "The most capable, and the default. The difference shows in the ranking and the brief, which weigh a setup against your circumstances rather than reading numbers off a page.",
            suitableForJudgement: true
        ),
        ModelOption(
            modelId: "claude-sonnet-5", name: "Sonnet 5",
            inputPerMTok: 2, outputPerMTok: 10,
            supportsEffort: true, adaptiveThinking: true,
            note: "Around 40% of the cost. A reasonable choice for the whole analysis if you run it often, and a strong one for the screening pass while Opus keeps the ranking and the brief.",
            suitableForJudgement: true
        ),
        ModelOption(
            modelId: "claude-haiku-4-5", name: "Haiku 4.5",
            inputPerMTok: 1, outputPerMTok: 5,
            supportsEffort: false, adaptiveThinking: false,
            note: "The cheapest. Suited to screening, which reads a metric pack and emits structured JSON. Not recommended for the brief.",
            suitableForJudgement: false
        ),
        ModelOption(
            modelId: "claude-opus-4-8", name: "Opus 4.8",
            inputPerMTok: 5, outputPerMTok: 25,
            supportsEffort: true, adaptiveThinking: true,
            note: "The previous Opus, at the same rate. Here for accounts that have it enabled and not the newer one.",
            suitableForJudgement: true
        ),
    ]

    static let fallback = all[0]

    static func of(_ modelId: String) -> ModelOption? { all.first { $0.modelId == modelId } }

    /// A model the app does not know, chosen through the environment. Priced where
    /// possible and assumed to take the modern request shape.
    static func describe(_ modelId: String) -> ModelOption {
        if let known = of(modelId) { return known }
        let price = ModelPrice.of(modelId)
        return ModelOption(
            modelId: modelId, name: modelId,
            inputPerMTok: price?.inputPerMTok ?? 0,
            outputPerMTok: price?.outputPerMTok ?? 0,
            supportsEffort: true, adaptiveThinking: true,
            note: "Set outside the app. Paper does not know this model, so it assumes the current request shape and, without a published rate, reports token counts without a cost.",
            suitableForJudgement: true
        )
    }

    /**
     * Which passes go to the cheaper model when one is chosen.
     *
     * Screening and the per-trade review notes are both mechanical reads of prepared
     * evidence. The ranking, the brief, the period report and the learning pass all
     * involve weighing one thing against another, and that is the whole reason to pay
     * for a larger model.
     */
    static let mechanicalPasses: Set<String> = ["screen", "review"]
}

/**
 * The models currently in force.
 *
 * Held behind a lock rather than an actor because it is read from every call site
 * in the analyst — including inside concurrent task groups — and written only when
 * a setting changes. An actor here would make every read `await` for no benefit.
 */
enum AnalystModel {

    private static let lock = NSLock()
    nonisolated(unsafe) private static var main: String?
    nonisolated(unsafe) private static var fast: String?

    /// The environment still works, and now loses to a choice made in the app — the
    /// same precedence the API key uses, for the same reason: a setting someone just
    /// picked should be the one in use, not one silently outranked by a shell export
    /// they made three months ago.
    private static var environmentModel: String? {
        let value = ProcessInfo.processInfo.environment["PAPER_MODEL"]
        return (value?.isEmpty ?? true) ? nil : value
    }

    static func adopt(main: String?, fast: String?) {
        lock.lock()
        defer { lock.unlock() }
        self.main = (main?.isEmpty ?? true) ? nil : main
        self.fast = (fast?.isEmpty ?? true) ? nil : fast
    }

    /// The model that does the thinking.
    static var current: String {
        lock.lock()
        defer { lock.unlock() }
        return main ?? environmentModel ?? ModelCatalogue.fallback.modelId
    }

    /// The model set for the mechanical passes, when one is set at all.
    static var currentFast: String? {
        lock.lock()
        defer { lock.unlock() }
        return fast
    }

    /// Where the model in force came from, for the interface to say so.
    static var source: String {
        lock.lock()
        let chosen = main
        lock.unlock()
        if chosen != nil { return "chosen in Settings" }
        if environmentModel != nil { return "PAPER_MODEL in the environment" }
        return "the app's default"
    }

    /// The model a given pass will actually use.
    static func forPass(_ pass: String) -> String {
        guard ModelCatalogue.mechanicalPasses.contains(pass), let fast = currentFast else {
            return current
        }
        return fast
    }
}
