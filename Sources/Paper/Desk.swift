/**
 * Desk.swift — the engine behind the window.
 *
 * Owns the profiles, one ledger per profile, the shared market read, the analyst
 * jobs, and the routes the web front end calls. Everything the interface knows
 * comes from here; the WKWebView is a renderer with no state of its own.
 *
 * Market data is shared across profiles because a price is a price. Everything
 * downstream of it — what is eligible, how big, how long, what it costs — is the
 * profile's, which is why two accounts looking at the same board are shown
 * different trades.
 *
 * Nothing in this file can move real money: there is no brokerage credential, no
 * order endpoint pointing outward, and the only writes are to JSON ledgers of
 * imaginary positions.
 */

import Foundation

/* ------------------------------------------------------- response shapes */

/**
 * One read per market on the board.
 *
 * Stockholm gets its own rather than being folded into `stocks`, because it is a
 * different market and averaging the two produces a number true of neither. Swedish
 * industrials running while US tech stalls is an ordinary quarter, and a single
 * breadth figure across both would have shown a flat market on a day when there
 * were two clear and opposite trends to trade.
 */
struct Regimes: Codable {
    let stocks: Analysis.MarketRegime
    let crypto: Analysis.MarketRegime
    let sweden: Analysis.MarketRegime

    /// Every read, for the prompts and the interface, in a stable order.
    var all: [Analysis.MarketRegime] { [stocks, sweden, crypto] }

    /// The read that actually governs a given instrument.
    func forSymbol(_ symbol: String) -> Analysis.MarketRegime {
        switch Universe.venue(of: symbol) {
        case .crypto: return crypto
        case .stockholm: return sweden
        case .us: return stocks
        }
    }
}

struct SuitabilityView: Codable {
    let capacity: Double
    let statedRiskPct: Double
    let suitableRiskPct: Double
    let effectiveRiskPct: Double
    let capped: Bool
    let maxHeatPct: Double
    let note: String
}

struct SessionView: Codable {
    let equityMarketOpen: Bool
    let note: String
    /// Nil when the account is above the pattern-day-trader threshold, or the
    /// profile does not enforce it.
    let dayTradesLeft: Int?
    /// Every exchange on the board, each with its own clock. The single boolean
    /// above is kept for the badge; anything that names a market reads this.
    var clocks: [MarketClock] = []
}

struct ProfileSummary: Codable {
    let id: String
    let name: String
    let note: String
    let goal: String
    let horizon: String
    let equity: Double
    let totalPnlPct: Double
    let openPositions: Int
    let active: Bool
    /// The currency this account prints its companion figures in. Every equity
    /// figure on the switcher is dollars regardless, which is what makes them
    /// comparable — the switcher is the one place several accounts are read at once,
    /// and the only way that comparison means anything is if all of them are in the
    /// same unit. Carried here so a per-account reading currency stays possible.
    let currency: Currency
}

struct StateResponse: Codable {
    let portfolio: Valued
    let startingCash: Double
    let equityCurve: [EquityPoint]
    let trades: [Trade]
    let scorecard: Scorecard
    let regimes: Regimes
    let cryptoGlobal: CryptoGlobal?
    let analyst: AnalystStatus
    let asOf: Double
    let pricesAt: Double
    let barsAt: Double

    let profile: Profile
    let profiles: [ProfileSummary]
    let suitability: SuitabilityView
    let session: SessionView
    let tax: TaxSummary
    let contributions: [Contribution]

    /// What the account reads in, and the rate that got it there.
    let currency: Currency
    let fx: FXRates
    /// The dollar value of the positions held, which is the FX exposure a real
    /// account funded in the reading currency would also be carrying.
    let foreignExposureUSD: Double

    /// Enough of the memory for the header and the desk; the full set is its own route.
    let learning: LearningSummary
    let hasOnboarded: Bool
    /// Enough of a running session for the top bar; the full picture is its own route.
    let liveSession: LiveSessionBadge?
    /**
     * Set when this account's file could not be read, and the ledger has therefore
     * gone read-only. It rides on the state response rather than sitting behind a
     * route somebody has to know to ask for, because the one thing worse than
     * refusing to write is refusing to write *quietly* while the desk shows a zero
     * balance that looks like a real one.
     */
    let ledgerError: String?
    /// The reading modes and what each one does, so the interface never keeps its
    /// own copy of a list the engine also holds.
    let readingModes: [ReadingModeView]
}

/// One reading mode, flattened for the interface.
struct ReadingModeView: Codable {
    let id: String
    let label: String
    let note: String
    let landing: String
    let landingSection: String?
    let explains: Bool
    let analystTabLabel: String

    init(_ m: ReadingMode) {
        id = m.rawValue
        label = m.label
        note = m.note
        landing = m.landing
        landingSection = m.landingSection
        explains = m.explains
        analystTabLabel = m.analystTabLabel
    }
}

struct LiveSessionBadge: Codable {
    let status: String
    let secondsLeft: Double
    let total: Double
    let lossLimit: Double
    let targetAmount: Double
    let tradesTaken: Int
    let maxTrades: Int
}

struct LearningSummary: Codable {
    let applied: Int
    let proposed: Int
    let watching: Int
    let analysesRun: Int
    let calibrationLines: [String]
    /// One line for the desk: what the engine is currently doing differently.
    let headline: String
}

struct MarketRow: Codable {
    let symbol: String
    let name: String
    let klass: AssetClass
    let sector: String
    let note: String
    let benchmark: Bool
    let quote: Quote?
    let metrics: Analysis.Metrics
    let plan: Analysis.TradePlan
    /// False when this profile's universe excludes the instrument entirely.
    let inUniverse: Bool
    let venue: Venue
    /// What the prices on this row are quoted in. The interface formats from this
    /// rather than assuming dollars, which is how a 337 kr stock reads as $337.
    let currency: String
    /// Whether this row's exchange is trading right now.
    let marketOpen: Bool
}

/// One exchange's clock, for the interface to show both without recomputing either.
struct MarketClock: Codable {
    let venue: Venue
    let label: String
    let name: String
    let currency: String
    let open: Bool
    let note: String

    init(_ venue: Venue) {
        self.venue = venue
        label = venue.label
        name = venue.exchangeName
        currency = venue.currency.code
        open = MarketCalendar.isSessionOpen(venue: venue)
        note = MarketCalendar.sessionNote(venue: venue)
    }
}

struct MarketsResponse: Codable {
    let rows: [MarketRow]
    let regimes: Regimes
    let asOf: Double
    let pricesAt: Double
    let barsAt: Double
}

struct InstrumentResponse: Codable {
    let instrument: Instrument
    let quote: Quote?
    let metrics: Analysis.Metrics
    let plan: Analysis.TradePlan
    let bars: [Bar]
    let news: [Headline]
    let inUniverse: Bool
}

struct AnalysisJob: Codable {
    var status: String = "idle"   // idle | running | done | error
    /// "ideas" or "review" — which side of the analyst is working.
    var kind: String = "ideas"
    var stage: AnalystStage?
    var startedAt: Double = 0
    var finishedAt: Double = 0
    var error: String?
    var candidates: Int = 0

    /// Spend, read live while the run is in flight. Watching a number climb is the
    /// only honest way to understand what an analysis costs, and it is the thing a
    /// budget is otherwise asking you to take on trust.
    var tokensSpent: Int = 0
    var tokensBudget: Int = 0
    var callsMade: Int = 0
    var estimatedCost: Double?
    /// Set when the governor ended the run rather than the pipeline finishing.
    var stoppedBy: String?
}

/// What a finished ideas run leaves on disk, so the Analyst tab survives a relaunch.
/**
 * An instrument the engine looked at and did not put on the shortlist, and why.
 *
 * Worth surfacing rather than discarding. A shortlist alone is unfalsifiable: it
 * shows twelve names and gives no way to tell a board with two good ideas from a
 * board with forty, or to notice that the reason a name is absent is a
 * concentration cap rather than a bad chart. The refusals are where most of the
 * teaching is, and they were being computed and thrown away.
 */
struct NearMiss: Codable {
    let symbol: String
    let name: String
    let sector: String
    let venue: String
    /// Nil where the setup was refused before a score was worth computing.
    let conviction: Double?
    /// Where it placed among everything that cleared the engine, when it cleared it.
    let rank: Int?
    let reason: String
    /// One of: rejected, floor, sector, complex, rank, universe.
    let kind: String
}

struct CachedAnalysis: Codable {
    var at: Double
    var profileId: String
    var reads: [ScreenRead]
    var ranking: RankOutput?
    var briefs: [BriefOut]
    /// Carried with the run so the written-up result never depends on a board
    /// fetch that may have been invalidated since.
    var plans: [String: Analysis.TradePlan]
    var metrics: [String: Analysis.Metrics]
    var ms: Double
    var passes: [String]
    var engineOnly: Bool
    /// The horizon this run was scored for. A run is only comparable to another
    /// run of the same style, so the style travels with the result.
    var style: String = TimeHorizon.swing.rawValue
    var nearMisses: [NearMiss] = []
    /// How many instruments were read before anything was cut.
    var considered: Int = 0

    init(at: Double, profileId: String, reads: [ScreenRead], ranking: RankOutput?,
         briefs: [BriefOut], plans: [String: Analysis.TradePlan],
         metrics: [String: Analysis.Metrics], ms: Double, passes: [String],
         engineOnly: Bool, style: String = TimeHorizon.swing.rawValue,
         nearMisses: [NearMiss] = [], considered: Int = 0) {
        self.at = at; self.profileId = profileId; self.reads = reads
        self.ranking = ranking; self.briefs = briefs; self.plans = plans
        self.metrics = metrics; self.ms = ms; self.passes = passes
        self.engineOnly = engineOnly; self.style = style
        self.nearMisses = nearMisses; self.considered = considered
    }

    /// A cache from an older build reads rather than being discarded.
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        at = try c.decodeIfPresent(Double.self, forKey: .at) ?? 0
        profileId = try c.decodeIfPresent(String.self, forKey: .profileId) ?? ""
        reads = try c.decodeIfPresent([ScreenRead].self, forKey: .reads) ?? []
        ranking = try c.decodeIfPresent(RankOutput.self, forKey: .ranking)
        briefs = try c.decodeIfPresent([BriefOut].self, forKey: .briefs) ?? []
        plans = try c.decodeIfPresent([String: Analysis.TradePlan].self, forKey: .plans) ?? [:]
        metrics = try c.decodeIfPresent([String: Analysis.Metrics].self, forKey: .metrics) ?? [:]
        ms = try c.decodeIfPresent(Double.self, forKey: .ms) ?? 0
        passes = try c.decodeIfPresent([String].self, forKey: .passes) ?? []
        engineOnly = try c.decodeIfPresent(Bool.self, forKey: .engineOnly) ?? false
        style = try c.decodeIfPresent(String.self, forKey: .style) ?? TimeHorizon.swing.rawValue
        nearMisses = try c.decodeIfPresent([NearMiss].self, forKey: .nearMisses) ?? []
        considered = try c.decodeIfPresent(Int.self, forKey: .considered) ?? 0
    }
}

/**
 * The engine's own shortlist for a horizon, with no model called and nothing
 * billed.
 *
 * This exists because of a specific complaint: the analyst kept returning the
 * same names, and the only way to find out was to pay for a full run and read
 * what came back. The shortlist is pure arithmetic over bars the board already
 * holds, so it can be shown the instant a horizon is picked — which makes the
 * difference between the four visible for free, and makes a paid run a decision
 * rather than a guess.
 */
struct ShortlistResponse: Codable {
    let style: String
    let label: String
    let emphasis: String
    let considered: Int
    let picks: [ShortlistPick]
    let nearMisses: [NearMiss]
}

struct ShortlistPick: Codable {
    let symbol: String
    let name: String
    let sector: String
    let venue: String
    let currency: String
    let conviction: Double
    /// Before this desk's learned bias, when the two differ.
    let rawConviction: Double
    let regime: String
    let rr: Double
    let entry: Double
    let stop: Double
    let target: Double
    let scores: Analysis.Scores
}

struct AnalysisResponse: Codable {
    let at: Double
    let reads: [ScreenRead]
    let ranking: RankOutput?
    let briefs: [BriefOut]
    let plans: [String: Analysis.TradePlan]
    let metrics: [String: Analysis.Metrics]
    let ms: Double
    let passes: [String]
    let engineOnly: Bool
    let job: AnalysisJob
    /// Why the last run ended the way it did, worked out locally without the API.
    let diagnosis: Diagnosis?
    let style: String
    let nearMisses: [NearMiss]
    let considered: Int
    /// Every style that can be asked for, so the picker is built from the engine's
    /// own list rather than a copy of it in the front end.
    let styles: [StyleOption]
}

/// One horizon the analyst can be pointed at, described in the terms the picker
/// needs to say what choosing it would change.
struct StyleOption: Codable {
    let id: String
    let label: String
    let short: String
    let emphasis: String
    let holdFor: String

    init(_ h: TimeHorizon) {
        id = h.rawValue
        label = h.label
        short = h.label.components(separatedBy: " —").first ?? h.rawValue
        emphasis = h.emphasis
        let band = h.sessionBand
        holdFor = "about \(Int(band.min))–\(Int(band.max)) sessions"
    }
}

/// What a finished review run leaves on disk.
struct CachedReview: Codable {
    var at: Double
    var profileId: String
    var notes: [TradeNote]
    var report: PeriodReport?
    var passes: [String]
    var engineOnly: Bool
}

struct ReviewResponse: Codable {
    /// Computed fresh on every request — the forensics are arithmetic and cost nothing.
    let reviews: [TradeReview]
    let behaviour: BehaviourReport
    let tax: TaxSummary
    /// The written half, from the last paid run.
    let at: Double
    let notes: [TradeNote]
    let report: PeriodReport?
    let passes: [String]
    let engineOnly: Bool
    let job: AnalysisJob
    /// Why the last run ended the way it did, worked out locally without the API.
    let diagnosis: Diagnosis?
}

/// The Learning tab's whole payload.
struct MemoryResponse: Codable {
    let profileId: String
    let lessons: [Lesson]
    let calibration: Calibration
    let calibrationLines: [String]
    let analysesRun: Int
    let updatedAt: Double
    /// Every run this account has made, newest first, with whatever the market has
    /// since said about each pick.
    let runs: [RunRecord]
    /// How the engine's own recommendations have scored so far.
    let scoreboard: EngineScoreboard
    /// What the last learning pass said it could not yet conclude.
    let notYetSupported: String?
}

/// The engine grading itself, over every recommendation old enough to have an
/// answer — taken or not. This is the number that says whether the calibration is
/// working, and it is the one a trade log can never produce.
struct EngineScoreboard: Codable {
    let graded: Int
    let resolved: Int
    let hitTarget: Int
    let hitStop: Int
    let recoveredAfterStop: Int
    let ranOnAfterTarget: Int
    let avgR: Double?
    /// Of the recommendations that were funded, versus the ones that were not.
    let takenAvgR: Double?
    let untakenAvgR: Double?
    let verdict: String
}

struct SettingsResponse: Codable {
    let hasOnboarded: Bool
}

/**
 * What a full reset would destroy, counted before it is offered.
 *
 * "Are you sure?" is not a confirmation, because it does not tell you what you are
 * confirming. This does: the number of accounts, the trades in them, what the
 * engine has learned and how long it took to learn it. The record is the part of
 * this app worth having, and someone about to delete it should be told its size.
 */
struct ResetPreview: Codable {
    let profiles: Int
    let trades: Int
    let openPositions: Int
    let closedTrades: Int
    let lessons: Int
    let appliedLessons: Int
    let analysisRuns: Int
    let sessions: Int
    /// Days between the oldest account's creation and now.
    let oldestAccountDays: Int
    let hasKeychainKey: Bool
    let keySource: String
    let dataDirectory: String
    /// One line per thing that goes, for the dialog to list.
    let items: [String]
}

/// Everything the Analyst section of Settings shows: where the key came from, what
/// a run is allowed to spend, and what the last one actually did.
struct AnalystPanel: Codable {
    let credentials: Credentials.Status
    let model: String
    let modelPriced: Bool
    let inputPerMTok: Double?
    let outputPerMTok: Double?
    let limits: RunLimits
    let lastRun: RunTelemetry?
    /// Free, local, and computed without touching the API — which is the point.
    let selfCheck: Diagnosis

    /// Everything the model picker needs.
    let models: [ModelOption]
    /// The model doing the judgement, and where that choice came from.
    let modelSource: String
    /// The cheaper model for the mechanical passes, when one is set.
    let fastModel: String?
    /// Which passes the cheaper model would take.
    let mechanicalPasses: [String]
    /// What one run at the current mix would cost against one on the default,
    /// as a multiplier. Stated rather than implied.
    let relativeCost: Double
}

struct ExplainResponse: Codable {
    let brief: BriefOut?
    let plan: Analysis.TradePlan
    let metrics: Analysis.Metrics
    let available: Bool
}

/* ---------------------------------------------------------------- the desk */

actor Desk {
    static let shared = Desk()

    /// The ledgers live where a Mac app keeps its documents, not next to the
    /// source, so a rebuild or a move of the project folder cannot take an account
    /// history with it.
    /**
     * Where the ledgers live.
     *
     * `PAPER_DATA_DIR` moves them, and exists for one reason: so a build can be
     * exercised end to end — real prices, real fills, the whole board — without
     * opening the accounts someone actually keeps. Verifying a change by running
     * it against the real ledger is how a real ledger gets damaged, and this app
     * has damaged one before.
     */
    static let dataDirectory: URL = {
        if let override = ProcessInfo.processInfo.environment["PAPER_DATA_DIR"], !override.isEmpty {
            log("[desk] PAPER_DATA_DIR is set — using \(override) instead of the normal location.")
            return URL(fileURLWithPath: (override as NSString).expandingTildeInPath, isDirectory: true)
        }
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        return base.appendingPathComponent("Paper", isDirectory: true)
    }()

    private let profilesURL = Desk.dataDirectory.appendingPathComponent("profiles.json")
    private let analysisURL = Desk.dataDirectory.appendingPathComponent("analysis.json")
    private let reviewURL = Desk.dataDirectory.appendingPathComponent("review.json")
    private var ledgersDirectory: URL { Desk.dataDirectory.appendingPathComponent("ledgers", isDirectory: true) }

    private struct ProfilesFile: Codable {
        var profiles: [Profile]
        var activeId: String
    }

    private struct Board {
        let metrics: [String: Analysis.Metrics]
        let quotes: [String: Quote]
        /// Today's opening print per symbol, so a gapped stop fills where the
        /// market actually was.
        let opens: [String: Double]
        let regimes: Regimes
        let cryptoGlobal: CryptoGlobal?
        let at: Double
        /// Exchange timestamp on the freshest quote — what "live" actually means here.
        let pricesAt: Double
        /// When the daily bars behind the metrics were pulled.
        let barsAt: Double
        /// Held for the review forensics, which need the whole series.
        let bars: [String: [Bar]]
        /// Corporate actions, so the reconciliation pass can tell a 10:1 split from
        /// a 90% crash. Without them it cannot, and it guesses wrong.
        let splits: [String: [Split]]
        /// The rates on the same clock as the prices. A board that marks a kronor
        /// holding with a rate from an hour ago is reporting a number nobody could
        /// have dealt at, so the two travel together.
        let fx: FXRates
    }

    private struct BarsSnapshot {
        let at: Double
        let bars: [String: [Bar]]
        let quotes: [String: Quote]
        let splits: [String: [Split]]
    }

    private var profiles: [Profile] = []
    private var activeId: String = ""
    private var ledgers: [String: Portfolio] = [:]

    private var board: Board?
    private var boardInFlight: Task<Board, Never>?
    private var barsCache: BarsSnapshot?
    private var barsInFlight: Task<BarsSnapshot, Never>?
    private var job = AnalysisJob()
    private var analysisTask: Task<Void, Never>?

    /// One memory per profile, held in step with its ledger. Loaded lazily and
    /// written on every change, because a lesson lost to a crash is a lesson the
    /// user has to be taught by the market twice.
    private var memories: [String: Memory] = [:]
    private var memoryDirectory: URL { Desk.dataDirectory.appendingPathComponent("memory", isDirectory: true) }
    private var fx: FXRates = .unavailable
    private var settings = AppSettings()
    private var settingsURL: URL { Desk.dataDirectory.appendingPathComponent("settings.json") }
    /// The last thing the learning pass said it could not yet conclude.
    private var notYetSupported: [String: String] = [:]

    /// The governor for the run currently in flight, so the interface can stop it
    /// and so the job can report live spend.
    private var governor: Governor?
    /// One running session per profile, at most.
    private var sessions: [String: TradingSession] = [:]
    /// The last finished run's full accounting, kept on disk so the token report
    /// survives a relaunch.
    private var lastRun: RunTelemetry?
    private var telemetryURL: URL { Desk.dataDirectory.appendingPathComponent("analyst-runs.json") }

    /* -------------------------------------------------------------- lifecycle */

    var activeProfile: Profile {
        profiles.first { $0.id == activeId } ?? profiles.first ?? Profile.preset(.learner)
    }

    /// The active account's id on its own, for callers that need to address a
    /// per-profile subsystem without pulling the whole profile across the actor.
    var activeProfileId: String { activeProfile.id }

    private var ledger: Portfolio { ledger(for: activeProfile) }

    /**
     * Copy every ledger aside on launch, before anything reads or writes them.
     *
     * The order is the entire point. A backup taken after the app has opened its own
     * files is a backup of whatever the app has already done to them — which on
     * 2026-09-13 meant faithfully preserving six ledgers that had been blanked four
     * minutes earlier. This runs first, from raw bytes, and never touches the
     * originals.
     */
    static func backupLedgers(in directory: URL) {
        let fm = FileManager.default
        let ledgers = (try? fm.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil))?
            .filter { $0.pathExtension == "json" } ?? []
        guard !ledgers.isEmpty else { return }

        let store = directory.appendingPathComponent("backups", isDirectory: true)
        try? fm.createDirectory(at: store, withIntermediateDirectories: true)

        let stamp = ISO8601DateFormatter().string(from: Date())
            .replacingOccurrences(of: ":", with: "-")
        let run = store.appendingPathComponent(stamp, isDirectory: true)
        try? fm.createDirectory(at: run, withIntermediateDirectories: true)

        var copied = 0
        for file in ledgers {
            // Read and write the bytes rather than copying the item: a copy that fails
            // silently is indistinguishable from a backup that was never needed.
            guard let bytes = try? Data(contentsOf: file) else { continue }
            if (try? bytes.write(to: run.appendingPathComponent(file.lastPathComponent))) != nil { copied += 1 }
        }
        if copied == 0 { try? fm.removeItem(at: run); return }
        log("[ledger] backed up \(copied) ledger(s) to backups/\(stamp) before opening them")

        // Keep the last twenty launches. Enough to walk back past a bad build without
        // the directory becoming its own problem.
        let runs = ((try? fm.contentsOfDirectory(at: store, includingPropertiesForKeys: nil)) ?? [])
            .filter { (try? $0.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true }
            .sorted { $0.lastPathComponent > $1.lastPathComponent }
        for stale in runs.dropFirst(20) { try? fm.removeItem(at: stale) }
    }

    private func ledger(for profile: Profile) -> Portfolio {
        if let existing = ledgers[profile.id] {
            existing.profile = profile
            return existing
        }
        let url = ledgersDirectory.appendingPathComponent("\(profile.id).json")
        let p = Portfolio(profile: profile, url: url)
        ledgers[profile.id] = p
        return p
    }

    /**
     * Brings the profiles up. On a first run the five presets are written out, so
     * the app opens with something to look at rather than an empty configuration
     * screen.
     */
    func openLedgers() {
        try? FileManager.default.createDirectory(at: ledgersDirectory, withIntermediateDirectories: true)
        // Before a single ledger is opened, and therefore before any code path can
        // write one.
        Desk.backupLedgers(in: ledgersDirectory)

        if let data = try? Data(contentsOf: profilesURL),
           let parsed = try? JSONDecoder().decode(ProfilesFile.self, from: data),
           parsed.profiles.contains(where: { Profile.isValidID($0.id) }) {
            // A profiles file is only ever written by this app, but its ids become file
            // names, so an edited or damaged one cannot point a ledger outside the folder.
            profiles = parsed.profiles.filter { Profile.isValidID($0.id) }
            let parsed = ProfilesFile(profiles: profiles, activeId: parsed.activeId)
            activeId = parsed.profiles.contains { $0.id == parsed.activeId } ? parsed.activeId : parsed.profiles[0].id
        } else {
            profiles = [
                Profile.preset(.learner),
                Profile.preset(.dayTrader),
                Profile.preset(.longTermGrower),
                Profile.preset(.cryptoNative),
                Profile.preset(.capitalToProtect),
            ]
            activeId = profiles[0].id
            persistProfiles()
        }

        for profile in profiles { _ = ledger(for: profile) }
        for profile in profiles { _ = memory(for: profile.id) }
        loadSettings()
        AnalystModel.adopt(main: settings.analystModel, fast: settings.analystFastModel)
    }

    private func persistProfiles() {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        guard let data = try? encoder.encode(ProfilesFile(profiles: profiles, activeId: activeId)) else { return }
        try? FileManager.default.createDirectory(at: Desk.dataDirectory, withIntermediateDirectories: true)
        try? data.write(to: profilesURL)
    }

    /* ---------------------------------------------------------- the memory */

    /**
     * Memories whose file exists but would not decode.
     *
     * While a profile is in here its memory is never written, for the same reason
     * the ledger refuses: answering an unreadable file by constructing an empty one
     * and saving it is not resilience, it is deletion with extra steps. The lessons
     * a desk has drawn from its own record cannot be reconstructed from anything
     * else, so an unreadable memory is a thing to show someone, not a thing to
     * replace.
     */
    private var memoryReadFailures: [String: String] = [:]

    private func memory(for profileId: String) -> Memory {
        if let held = memories[profileId] { return held }
        let url = memoryDirectory.appendingPathComponent("\(profileId).json")

        var loaded: Memory
        if let data = try? Data(contentsOf: url) {
            do {
                loaded = try JSONDecoder().decode(Memory.self, from: data)
            } catch {
                // The bytes are kept where they are, and a copy is set aside, exactly
                // as an unreadable ledger is.
                let stamp = ISO8601DateFormatter().string(from: Date())
                    .replacingOccurrences(of: ":", with: "-")
                let aside = memoryDirectory
                    .appendingPathComponent("\(profileId).unreadable-\(stamp).json")
                try? data.write(to: aside)
                memoryReadFailures[profileId] =
                    "This account\u{2019}s learning memory could not be read, so nothing will be written to it. "
                    + "The file has not been changed, and a copy is at \(aside.lastPathComponent). Reason: \(error)"
                log("[memory] REFUSING TO WRITE \(profileId): \(error)", .error, "memory")
                loaded = Memory.empty(profileId)
            }
        } else {
            // No file at all is a genuinely new memory, and writing one is correct.
            loaded = Memory.empty(profileId)
        }

        // Recomposed on load rather than trusted from disk: the calibration is a
        // derived value, and a hand-edited or half-written file must not be able to
        // put a number into the risk engine that no lesson accounts for.
        loaded.recompose()
        memories[profileId] = loaded
        return loaded
    }

    /// Set when this profile's memory file could not be read, for the interface
    /// to surface rather than let the desk look like it has simply learned nothing.
    func memoryError(for profileId: String) -> String? { memoryReadFailures[profileId] }

    private func save(_ memory: Memory) {
        var m = memory
        m.recompose()
        memories[m.profileId] = m
        guard memoryReadFailures[m.profileId] == nil else { return }
        try? FileManager.default.createDirectory(at: memoryDirectory, withIntermediateDirectories: true)
        write(m, to: memoryDirectory.appendingPathComponent("\(m.profileId).json"))
    }

    /// The calibration in force for a profile, and the text the analyst is told.
    private func calibration(_ profile: Profile) -> Calibration { memory(for: profile.id).calibration }

    private func learningSummary(_ profile: Profile) -> LearningSummary {
        let m = memory(for: profile.id)
        let lines = m.calibration.lines
        let headline: String
        if m.applied.isEmpty && m.open.isEmpty {
            headline = m.analysesRun == 0
                ? "Nothing learned yet. The engine starts from its textbook settings and changes as your record fills in."
                : "Nothing learned yet: \(m.analysesRun) \(m.analysesRun == 1 ? "analysis" : "analyses") run, and no pattern has cleared its evidence threshold."
        } else if !m.open.isEmpty {
            headline = "\(m.open.count) proposed change\(m.open.count == 1 ? "" : "s") waiting on you"
                + (m.applied.isEmpty ? "." : ", \(m.applied.count) already applied.")
        } else {
            headline = "\(m.applied.count) lesson\(m.applied.count == 1 ? "" : "s") applied"
                + (lines.isEmpty ? "." : " — \(lines.joined(separator: "; ")).")
        }
        return LearningSummary(
            applied: m.applied.count, proposed: m.open.count, watching: m.watching.count,
            analysesRun: m.analysesRun, calibrationLines: lines, headline: headline
        )
    }

    private func loadSettings() {
        if let data = try? Data(contentsOf: settingsURL),
           let parsed = try? JSONDecoder().decode(AppSettings.self, from: data) {
            settings = parsed
        }
        if let data = try? Data(contentsOf: telemetryURL),
           let parsed = try? JSONDecoder().decode(RunTelemetry.self, from: data) {
            lastRun = parsed
        }
    }

    /// Live spend, read off the governor while a run is in flight.
    private func jobSnapshot() async -> AnalysisJob {
        var j = job
        if let governor {
            let t = await governor.telemetry
            j.tokensSpent = t.billedTokens
            j.tokensBudget = t.budgetTokens
            j.callsMade = t.calls.count
            j.estimatedCost = t.estimatedCost
            j.stoppedBy = t.stoppedBy?.rawValue
        } else if let lastRun, job.status != "running" {
            j.tokensSpent = lastRun.billedTokens
            j.tokensBudget = lastRun.budgetTokens
            j.callsMade = lastRun.calls.count
            j.estimatedCost = lastRun.estimatedCost
            j.stoppedBy = lastRun.stoppedBy?.rawValue
        }
        return j
    }

    /// Closes out a run: the governor's record is diagnosed, kept and persisted.
    private func settle(_ governor: Governor) async {
        var interim = await governor.telemetry
        // Stamped before the diagnosis rather than after: the diagnosis quotes how
        // long the run took, and reading it from a telemetry whose finish time is
        // still zero produced a wildly negative number.
        interim.finishedAt = nowMs()
        let credentials = Credentials.resolve()
        let diagnosis = Diagnostics.diagnose(
            interim, limits: settings.analystLimits,
            keyPresent: credentials != nil,
            keySource: credentials?.source ?? .none
        )
        let finished = await governor.finish(diagnosis: diagnosis)
        lastRun = finished
        write(finished, to: telemetryURL)
        self.governor = nil

        if let cause = finished.stoppedBy, cause != .cancelled {
            job.error = diagnosis.headline + " — " + (finished.stopNote ?? "")
        }
        log("[analyst] run \(finished.kind): \(finished.calls.count) calls, \(finished.billedTokens) tokens"
            + (finished.estimatedCost.map { String(format: ", ~$%.2f", $0) } ?? "")
            + (finished.stoppedBy.map { ", stopped by \($0.rawValue)" } ?? ""))
    }

    private func persistSettings() { write(settings, to: settingsURL) }

    /* ------------------------------------------------- the shared market read */

    /// Bars are the expensive half and barely move intraday. Fetched once, reused.
    private func getBars(force: Bool = false) async -> BarsSnapshot {
        if !force, let barsCache, nowMs() - barsCache.at < 15 * 60_000 { return barsCache }
        if let barsInFlight { return await barsInFlight.value }

        let task = Task { () -> BarsSnapshot in
            var bars: [String: [Bar]] = [:]
            var quotes: [String: Quote] = [:]
            var splits: [String: [Split]] = [:]

            await withTaskGroup(of: (String, ChartData?).self) { group in
                for sym in Universe.symbols {
                    group.addTask {
                        // Two years, not one: a 1y window yields ~250 sessions, which is one
                        // short of the 252-session lookback, so the 1-year return comes back
                        // null. The extra history also steadies the 200-day average and gives
                        // the pivot scan something to work with.
                        //
                        // Skip a symbol the feed is unhappy about rather than fail the board.
                        let data = try? await Market.shared.chart(sym, range: "2y", interval: "1d")
                        return (sym, data)
                    }
                }
                for await (sym, data) in group {
                    guard let data else { continue }
                    bars[sym] = data.bars
                    quotes[sym] = data.quote
                    if !data.splits.isEmpty { splits[sym] = data.splits }
                }
            }
            return BarsSnapshot(at: nowMs(), bars: bars, quotes: quotes, splits: splits)
        }
        barsInFlight = task
        defer { barsInFlight = nil }
        let snapshot = await task.value
        barsCache = snapshot
        return snapshot
    }

    /**
     * The board: cached bars with live prices laid over them, and every metric
     * recomputed against the current price.
     *
     * The two halves refresh on very different clocks on purpose. Two years of daily
     * bars per symbol is one request per name and changes almost nothing during a session,
     * so it is held for fifteen minutes. The price is one batched request for the
     * whole universe, so it can run on a fifteen-second leash — which is what makes
     * the desk read as live rather than as a snapshot from when the window was opened.
     */
    @discardableResult
    private func getBoard(force: Bool = false) async -> Board {
        // A short structural cache purely to stop rapid polls recomputing the same thing.
        if !force, let board, nowMs() - board.at < 12_000 { return board }
        if let boardInFlight { return await boardInFlight.value }

        let task = Task { () -> Board in
            let snapshot = await self.getBars(force: force)

            // Force means the user pressed Refresh, and a refresh that returns the price
            // it already had is a refresh that lied.
            if force { await Market.shared.bust("spark:") }
            var live: [String: Quote] = [:]
            do {
                live = try await Market.shared.livePrices(Universe.symbols, ttlMs: force ? 0 : 15_000)
            } catch {
                // Falling back to bar prices is correct, but doing it silently is how a desk
                // ends up quietly showing a fifteen-minute-old price and calling it live.
                log("[market] live prices unavailable, falling back to bar closes: \(error.localizedDescription)", .warn, "market")
            }

            var metrics: [String: Analysis.Metrics] = [:]
            var quotes: [String: Quote] = [:]
            var opens: [String: Double] = [:]
            for sym in Universe.symbols {
                guard let b = snapshot.bars[sym] else { continue }
                guard let q = live[sym] ?? snapshot.quotes[sym] else { continue }
                quotes[sym] = q
                metrics[sym] = Analysis.analyse(sym, b, livePrice: q.price)
                if let last = b.last { opens[sym] = last.o }
            }

            // Breadth is only meaningful inside one market. A Swedish bank holding
            // its 50-day says nothing about whether the S&P has breadth.
            func members(_ venue: Venue) -> [Analysis.Metrics] {
                Universe.all
                    .filter { $0.venue == venue && !Universe.benchmarks.contains($0.symbol) }
                    .compactMap { metrics[$0.symbol] }
            }

            if live.count < Universe.symbols.count {
                log("[market] \(live.count)/\(Universe.symbols.count) live prices; the rest fall back to bar closes.")
            }

            // One extra batched request, on the same clock as the board. A converted
            // figure whose rate is stale is a wrong figure, not a slightly old one.
            let rates = await Market.shared.fxRates(ttlMs: force ? 0 : 600_000)
            self.adopt(rates)

            let built = Board(
                metrics: metrics, quotes: quotes, opens: opens,
                regimes: Regimes(
                    stocks: Analysis.marketRegime(metrics["SPY"], members(.us), "stocks"),
                    crypto: Analysis.marketRegime(metrics["BTC-USD"], members(.crypto), "crypto"),
                    sweden: Analysis.marketRegime(metrics["^OMX"], members(.stockholm), "sweden")
                ),
                cryptoGlobal: await Market.shared.cryptoGlobal(),
                at: nowMs(),
                pricesAt: quotes.values.map(\.asOf).max() ?? 0,
                barsAt: snapshot.at,
                bars: snapshot.bars,
                splits: snapshot.splits,
                fx: rates
            )

            // Every ledger is marked, not just the active one — a stop on a profile you
            // are not looking at still has to fire.
            await self.markAll(built)
            return built
        }
        boardInFlight = task
        defer { boardInFlight = nil }
        let built = await task.value
        board = built
        return built
    }

    private func adopt(_ rates: FXRates) { fx = rates }

    /**
     * The one place a mark is built.
     *
     * Every fill, every bracket sweep and every valuation goes through a `MarkPrice`,
     * and a `MarkPrice` without its exchange rate values a kronor holding as though
     * kronor were dollars — a tenfold error, silently, in the flattering direction.
     * Centralising construction means a new call site cannot forget the rate,
     * because there is nothing to forget.
     */
    private func mark(_ sym: String, _ b: Board) -> MarkPrice? {
        guard let q = b.quotes[sym] else { return nil }
        return MarkPrice(q, dayOpen: b.opens[sym], atr: b.metrics[sym]?.atr14,
                         fxPerUSD: b.fx.rate(Universe.currency(of: sym)))
    }

    private func marks(_ b: Board) -> [String: MarkPrice] {
        var out: [String: MarkPrice] = [:]
        for sym in b.quotes.keys {
            out[sym] = mark(sym, b)
        }
        return out
    }

    /**
     * Reconciles the closed window, pays in contributions, fires brackets and marks
     * the equity curve, on every ledger. Doing it here means it happens on each
     * refresh without a second timer to keep in sync.
     *
     * Order is load-bearing. The replay runs *first*, against completed daily bars
     * for the sessions nobody watched, and only then does the live sweep look at
     * today. Run the other way round, a position that should have been stopped out
     * on Tuesday would be marked at Friday's price before anything noticed it was
     * supposed to be closed.
     */
    private func markAll(_ b: Board) async {
        await reconcileAll(b)
        let priced = marks(b)
        for profile in profiles {
            let led = ledger(for: profile)
            // Idempotent by month key, so the replay having already paid these in is
            // not a double deposit.
            led.applyContribution()
            let fired = led.sweepBrackets(priced)
            if !fired.isEmpty {
                log("[brackets] \(profile.name): " + fired.map { "\($0.symbol) \($0.trigger ?? "manual")" }.joined(separator: ", "))
            }
            let v = led.value(priced)
            led.snapshot(equity: v.equity, cash: v.cash, invested: v.invested)
        }
    }

    /**
     * Hold every ledger to account for the market that passed while Paper was shut.
     *
     * Idempotent by construction: the replay only looks at bars after each ledger's
     * `lastSweptAt`, which this pass then advances to now, so running it on every
     * board refresh costs nothing after the first one.
     */
    private func reconcileAll(_ b: Board) async {
        for profile in profiles {
            let led = ledger(for: profile)
            let report = await Reconcile.run(
                ledger: led, profileName: profile.name, fx: b.fx,
                bars: b.bars, splits: b.splits,
                intraday: { symbol in
                    // Only ever reached when a daily bar had both legs inside it, so the
                    // common case costs no extra requests. Yahoo serves five-minute bars
                    // about sixty days back; past that the daily bar is the ceiling and
                    // the exit is labelled as assumed.
                    try? await Market.shared.chart(symbol, range: "1mo", interval: "5m").bars
                }
            )
            guard let report else { continue }
            reconciliations[profile.id] = report
            log("[reconcile] \(profile.name): \(report.sessionsReplayed) sessions replayed, "
                + "\(report.exits.count) exit(s) reconstructed, \(money(report.netPnl)) net"
                + (report.flagged.isEmpty ? "" : ", \(report.flagged.count) flagged for review"))
        }
    }

    /// The last reconciliation per profile, held for the interface to surface and
    /// for the principal to acknowledge. Not persisted: it describes one launch.
    private var reconciliations: [String: ReconcileReport] = [:]

    /// What the interface asks for, and what clears it once it has been seen.
    func reconciliation(for profileId: String) -> ReconcileReport? { reconciliations[profileId] }
    func acknowledgeReconciliation(_ profileId: String) { reconciliations[profileId] = nil }


    /**
     * The rules a plan is built under: the profile's, then whatever this account's
     * own record has taught the engine since.
     *
     * Every level on every screen comes through here, so an applied lesson takes
     * effect everywhere at once — the board, the drawer, the analyst and the order
     * ticket cannot disagree about where a stop belongs.
     */
    private func sizing(_ b: Board?, _ profile: Profile,
                        style: TimeHorizon? = nil) -> Analysis.SizingRules {
        let equity = b.map { ledger(for: profile).value(marks($0)).equity } ?? profile.startingCapital
        return calibration(profile).apply(to: profile.sizingRules(equity: equity, style: style))
    }

    /// Called on a timer so a target or stop fires whether or not anyone is looking
    /// at the window.
    func tick() async {
        let b = await getBoard()
        // A session's loss limit and its clock have to fire whether or not the tab is
        // open. That is the whole point of a limit set in advance.
        for profile in profiles where sessions[profile.id]?.status == .running || session(for: profile.id)?.status == .running {
            _ = refreshSession(profile, board: b)
        }
    }

    /* ------------------------------------------------------- analysis caching */

    private func readAnalysisCache() -> CachedAnalysis? {
        guard let data = try? Data(contentsOf: analysisURL) else { return nil }
        return try? JSONDecoder().decode(CachedAnalysis.self, from: data)
    }

    private func readReviewCache() -> CachedReview? {
        guard let data = try? Data(contentsOf: reviewURL) else { return nil }
        return try? JSONDecoder().decode(CachedReview.self, from: data)
    }

    private func write<T: Encodable>(_ value: T, to url: URL) {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        guard let data = try? encoder.encode(value) else { return }
        // The file's own parent, not the data root — several of these live in
        // subdirectories, and creating the wrong one makes the write fail silently.
        try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(),
                                                 withIntermediateDirectories: true)
        try? data.write(to: url)
    }

    /// What the shortlist run produced: what got through, and what did not.
    private struct Shortlist {
        var picks: [Candidate]
        var nearMisses: [NearMiss]
        /// Instruments read before anything was cut.
        var considered: Int
    }

    /**
     * The candidate set the analyst sees.
     *
     * Three things decide it, and the second and third are new because the first
     * alone is what made every run come back with the same names.
     *
     *   1. The engine. An instrument this profile may hold, whose plan survives the
     *      risk rules, scoring above this desk's learned conviction floor.
     *
     *   2. The style. Scores are recomputed for the horizon being asked about
     *      rather than read off a board computed for one fixed horizon. This is the
     *      part that changes *which* names appear: a day-trading read weights the
     *      last five sessions and the daily range, and a long-term read weights a
     *      year of trend and how deep the drawdowns ran. They do not agree, and
     *      they are not supposed to.
     *
     *   3. Concentration. Taking the top twelve by score is how a shortlist ends up
     *      being six semiconductor names and two bitcoin proxies — which is two
     *      bets wearing eight tickers, and the ranking pass could only warn about
     *      it after the fact. Sector and complex caps apply before the money does,
     *      and every venue this profile trades gets at least one place, so a
     *      Stockholm idea is not permanently buried under a hot US tape.
     *
     * Everything cut is kept with its reason rather than discarded.
     */
    private func candidates(_ b: Board, _ profile: Profile, limit: Int = 12,
                            style: TimeHorizon? = nil) -> Shortlist {
        let horizon = style ?? profile.horizon
        let rules = sizing(b, profile, style: horizon)
        let cal = calibration(profile)

        var eligible: [Candidate] = []
        var misses: [NearMiss] = []
        var considered = 0

        func miss(_ inst: Instrument, _ kind: String, _ reason: String,
                  conviction: Double? = nil, rank: Int? = nil) {
            misses.append(NearMiss(
                symbol: inst.symbol, name: inst.name, sector: inst.sector,
                venue: inst.venue.label, conviction: conviction, rank: rank,
                reason: reason, kind: kind
            ))
        }

        for inst in Universe.all {
            guard profile.allows(inst.symbol) else { continue }
            if Universe.benchmarks.contains(inst.symbol) && !profile.fundsBenchmarks { continue }
            // Scored for the horizon being asked about, from the bars the board
            // already holds. Recomputing is arithmetic over a cached series, so a
            // style switch costs no requests.
            guard let bars = b.bars[inst.symbol], bars.count >= 60 else { continue }
            let m = Analysis.analyse(inst.symbol, bars,
                                     livePrice: b.quotes[inst.symbol]?.price, style: horizon)
            considered += 1

            let plan = Analysis.buildPlan(m, rules)
            if let rejected = plan.rejected {
                miss(inst, "rejected", rejected, conviction: m.conviction)
                continue
            }

            // The learned bias moves the ordering and the floor. It never touches a
            // price: a conviction score is an opinion and a stop is arithmetic, and
            // letting experience edit the second is how an engine drifts.
            let learned = cal.conviction(m.conviction, symbol: m.symbol,
                                         sector: inst.sector, regime: m.regime.rawValue)
            guard learned >= cal.convictionFloor else {
                miss(inst, "floor",
                     "Scores \(f(learned, 0))/100 for a \(horizon.rawValue) horizon, under the \(f(cal.convictionFloor, 0)) floor this desk has settled on from its own record.",
                     conviction: learned)
                continue
            }

            eligible.append(Candidate(metrics: m, plan: plan, news: [], learnedConviction: learned))
        }

        eligible.sort { ($0.learnedConviction ?? 0) > ($1.learnedConviction ?? 0) }

        /* --- concentration ------------------------------------------------
         * At most a third of the shortlist from one sector, and at most two from
         * one correlated complex. The complex cap is the tighter of the two on
         * purpose: two sectors can genuinely diverge, while eight crypto proxies
         * cannot. */
        let sectorCap = Swift.max(2, Int((Double(limit) / 3).rounded(.down)))
        let complexCap = 2

        var picks: [Candidate] = []
        var bySector: [String: Int] = [:]
        var byComplex: [String: Int] = [:]
        var byVenue: [Venue: Int] = [:]
        var deferred: [(Candidate, Int, String, String)] = []   // candidate, rank, kind, reason

        for (index, c) in eligible.enumerated() {
            let sym = c.metrics.symbol
            let inst = Universe.bySymbol[sym]
            let sector = inst?.sector ?? "n/a"
            let venue = Universe.venue(of: sym)
            let rank = index + 1

            if picks.count >= limit {
                deferred.append((c, rank, "rank",
                    "Ranked \(rank) of \(eligible.count) setups that cleared the engine, outside the \(limit) the analyst reads."))
                continue
            }
            if let group = inst?.complex, (byComplex[group] ?? 0) >= complexCap {
                deferred.append((c, rank, "complex",
                    "Two names from the \(group) complex are already funded. A third is the same bet a third time, not a third idea."))
                continue
            }
            if (bySector[sector] ?? 0) >= sectorCap {
                deferred.append((c, rank, "sector",
                    "\(sectorCap) \(sector) names are already on the shortlist, which is the most one sector gets."))
                continue
            }

            picks.append(c)
            bySector[sector, default: 0] += 1
            byVenue[venue, default: 0] += 1
            if let group = inst?.complex { byComplex[group, default: 0] += 1 }
        }

        /* Every market this profile trades gets a seat, if it has earned one.
         *
         * Without this a strong run in one market buries the other entirely, and the
         * board silently becomes single-venue again — the exact failure that adding
         * Stockholm was meant to fix. The seat is taken from whichever venue is most
         * represented, and the displaced name is recorded as having been displaced
         * rather than as having scored badly.
         *
         * The band is what stops this becoming a quota. A seat exists so a market is
         * not *buried*; it does not exist to fund a weak idea because of where it is
         * listed. When a market's best candidate sits more than this far below the
         * weakest name already on the list, that market genuinely has nothing today,
         * and saying so is the more useful answer than promoting it anyway. */
        let seatBand = 12.0

        for venue in profile.activeVenues where (byVenue[venue] ?? 0) == 0 {
            let taken = Set(picks.map(\.metrics.symbol))
            guard let best = eligible.first(where: { candidate in
                Universe.venue(of: candidate.metrics.symbol) == venue
                    && !taken.contains(candidate.metrics.symbol)
            }) else { continue }

            if picks.count < limit {
                picks.append(best)
                byVenue[venue, default: 0] += 1
                continue
            }
            // Displace the weakest pick from the most crowded venue, never the only
            // representative of another one.
            guard let crowded = byVenue.max(by: { $0.value < $1.value })?.key,
                  (byVenue[crowded] ?? 0) > 1,
                  let dropIndex = picks.lastIndex(where: { Universe.venue(of: $0.metrics.symbol) == crowded })
            else { continue }

            let weakest = picks.map { $0.learnedConviction ?? 0 }.min() ?? 0
            let contender = best.learnedConviction ?? 0
            guard contender >= weakest - seatBand else {
                let inst = Universe.bySymbol[best.metrics.symbol]
                misses.append(NearMiss(
                    symbol: best.metrics.symbol, name: inst?.name ?? best.metrics.symbol,
                    sector: inst?.sector ?? "n/a", venue: venue.label,
                    conviction: contender, rank: nil,
                    reason: "The best \(venue.label) setup for this horizon, and still \(f(weakest - contender, 0)) points behind the weakest name on the list. A place is held for each market so none of them gets buried, but not at the price of funding a setup this far off — \(venue.label) has nothing worth taking today.",
                    kind: "venue"
                ))
                continue
            }

            let dropped = picks.remove(at: dropIndex)
            let droppedInst = Universe.bySymbol[dropped.metrics.symbol]
            misses.append(NearMiss(
                symbol: dropped.metrics.symbol, name: droppedInst?.name ?? dropped.metrics.symbol,
                sector: droppedInst?.sector ?? "n/a", venue: crowded.label,
                conviction: dropped.learnedConviction, rank: nil,
                reason: "Made room for a \(venue.label) idea. \(crowded.label) already held \(byVenue[crowded] ?? 0) of the \(limit) places, and a shortlist from one market is a shortlist with one weather system.",
                kind: "venue"
            ))
            byVenue[crowded, default: 1] -= 1
            picks.append(best)
            byVenue[venue, default: 0] += 1
            deferred.removeAll { $0.0.metrics.symbol == best.metrics.symbol }
        }

        for (c, rank, kind, reason) in deferred {
            let inst = Universe.bySymbol[c.metrics.symbol]
            misses.append(NearMiss(
                symbol: c.metrics.symbol, name: inst?.name ?? c.metrics.symbol,
                sector: inst?.sector ?? "n/a", venue: inst?.venue.label ?? "US",
                conviction: c.learnedConviction, rank: rank, reason: reason, kind: kind
            ))
        }

        // Best first among what cleared, then the refusals. Ordered so the list reads
        // as "closest to being funded" downwards.
        misses.sort { ($0.conviction ?? -1) > ($1.conviction ?? -1) }

        return Shortlist(picks: picks, nearMisses: misses, considered: considered)
    }

    private func setStage(_ stage: AnalystStage) { job.stage = stage }
    private func noteCandidateCount(_ n: Int) { job.candidates = n }

    private func finishJob() {
        job.status = "done"
        job.stage = .done
        job.finishedAt = nowMs()
    }

    private func failJob(_ message: String) {
        job.status = "error"
        job.stage = nil
        job.error = message
        job.finishedAt = nowMs()
    }

    /* ---------------------------------------------------------- the ideas run */

    /**
     * `style` is the trade being asked about, for this run only.
     *
     * Nil means the profile's own horizon, which is what pressing the button used to
     * do and still does. Passing one scores the same board for a different question
     * without touching the account: the limits, the risk per trade and the ledger
     * are the profile's, and only the read changes. Running all four in turn over
     * one afternoon is the point — the disagreement between them is the lesson.
     */
    private func startAnalysis(style: TimeHorizon? = nil) {
        let profile = activeProfile
        let horizon = style ?? profile.horizon
        job = AnalysisJob(status: "running", kind: "ideas", stage: nil,
                          startedAt: nowMs(), finishedAt: 0, error: nil, candidates: 0)
        analysisTask = Task {
            let b = await self.getBoard(force: true)
            let shortlist = self.candidates(b, profile, style: horizon)
            var cands = shortlist.picks
            self.noteCandidateCount(cands.count)

            var plans: [String: Analysis.TradePlan] = [:]
            var metrics: [String: Analysis.Metrics] = [:]
            for c in cands {
                plans[c.metrics.symbol] = c.plan
                metrics[c.metrics.symbol] = c.metrics
            }

            if cands.isEmpty {
                // Nothing funded is still a result, and the refusals are the whole of
                // it. Writing them means the screen can say what was looked at and why
                // none of it cleared, rather than going blank.
                self.write(CachedAnalysis(
                    at: nowMs(), profileId: profile.id, reads: [], ranking: nil, briefs: [],
                    plans: [:], metrics: [:], ms: 0, passes: ["no-eligible-setups"], engineOnly: true,
                    style: horizon.rawValue, nearMisses: shortlist.nearMisses,
                    considered: shortlist.considered
                ), to: self.analysisURL)
                self.finishJob()
                return
            }

            // Headlines only for what survives the engine — news is the slowest fetch
            // and there is no point pulling it for setups already refused.
            var newsBySymbol: [String: [Headline]] = [:]
            await withTaskGroup(of: (String, [Headline]).self) { group in
                for c in cands {
                    let sym = c.metrics.symbol
                    group.addTask { (sym, (try? await Market.shared.headlines(sym, count: 5)) ?? []) }
                }
                for await (sym, news) in group { newsBySymbol[sym] = news }
            }
            for i in cands.indices { cands[i].news = newsBySymbol[cands[i].metrics.symbol] ?? [] }

            let slots = Swift.max(1, Swift.min(profile.maxOpenPositions, 6))
            let brief = self.memoryBrief(profile)
            let gov = self.openGovernor(kind: "ideas")
            let result = await Analyst.analyse(cands, b.regimes.all, profile,
                                               slots: slots, memory: brief, governor: gov,
                                               style: horizon) { stage in
                Task { self.setStage(stage) }
            }

            // Recorded before anything is traded, so the engine can be graded on what
            // it recommended rather than on what happened to be acted upon.
            self.recordRun(profile: profile, candidates: cands, ranking: result.ranking, board: b)

            self.write(CachedAnalysis(
                at: nowMs(), profileId: profile.id, reads: result.reads, ranking: result.ranking,
                briefs: result.briefs, plans: plans, metrics: metrics, ms: result.ms,
                passes: result.passes, engineOnly: !Analyst.available(),
                style: horizon.rawValue, nearMisses: shortlist.nearMisses,
                considered: shortlist.considered
            ), to: self.analysisURL)
            await self.settle(gov)
            self.finishJob()
            log("[analyst] ideas run finished — \(result.passes.joined(separator: " → "))")

            if Analyst.available() && result.reads.isEmpty && self.lastRunStopCause() == nil {
                self.failJob("Every pass came back empty. The API key resolved, so this is a network or account problem rather than a missing credential. The engine's own ranking below is unaffected.")
            }
        }
    }

    private func memoryBrief(_ profile: Profile) -> String { memory(for: profile.id).brief }

    /// One governor per run, held so the interface can stop it mid-flight.
    private func openGovernor(kind: String) -> Governor {
        let g = Governor(kind: kind, model: Analyst.model, limits: settings.analystLimits)
        governor = g
        return g
    }

    private func lastRunStopCause() -> StopCause? { lastRun?.stoppedBy }

    /* ------------------------------------------------------- day-trading sessions */

    private var sessionsDirectory: URL { Desk.dataDirectory.appendingPathComponent("sessions", isDirectory: true) }

    private func session(for profileId: String) -> TradingSession? {
        if let held = sessions[profileId] { return held }
        let url = sessionsDirectory.appendingPathComponent("\(profileId).json")
        guard let data = try? Data(contentsOf: url),
              let parsed = try? JSONDecoder().decode(TradingSession.self, from: data) else { return nil }
        sessions[profileId] = parsed
        return parsed
    }

    private func save(_ session: TradingSession) {
        sessions[session.profileId] = session
        try? FileManager.default.createDirectory(at: sessionsDirectory, withIntermediateDirectories: true)
        write(session, to: sessionsDirectory.appendingPathComponent("\(session.profileId).json"))
    }

    /**
     * Five-minute bars for the session universe.
     *
     * A separate cache from the daily board on a much shorter leash: a five-minute
     * bar is stale the moment the next one prints, and a day-trading screen quoting a
     * fifteen-minute-old level would be worse than no screen.
     */
    private func intradayBars(_ symbols: [String]) async -> [String: [Bar]] {
        var out: [String: [Bar]] = [:]
        await withTaskGroup(of: (String, [Bar]).self) { group in
            for sym in symbols {
                group.addTask {
                    // Five days of five-minute bars is 391 of them — enough history for a
                    // 200-period average and an ATR to mean something at this timeframe.
                    let data = try? await Market.shared.chart(sym, range: "5d", interval: "5m")
                    return (sym, data?.bars ?? [])
                }
            }
            for await (sym, bars) in group where !bars.isEmpty { out[sym] = bars }
        }
        return out
    }

    /**
     * Reconciles a running session against the ledger, then applies its own rules.
     *
     * The brackets themselves are swept by the ordinary board refresh, so a session
     * position closes whether or not anyone is looking at this tab. What happens here
     * is the session's accounting of that, and the three rules that end it.
     */
    private func refreshSession(_ profile: Profile, board b: Board) -> TradingSession? {
        guard var current = session(for: profile.id) else { return nil }
        let led = ledger(for: profile)
        let state = led.state
        let priced = marks(b)
        var changed = false

        // --- entries closed before the cost field existed, or by an earlier build.
        //
        // Deliberately ahead of the "is it still running" guard: a finished session is
        // never re-evaluated against its rules, and it should not be, but its report is
        // read long afterwards. The most important line in that report is what the
        // trading cost, and an entry silently reporting zero would understate exactly
        // the number this mode exists to show.
        for i in current.entries.indices where current.entries[i].costs == nil && current.entries[i].closedAt != nil {
            let entry = current.entries[i]
            guard let sell = state.trades.first(where: {
                $0.symbol == entry.symbol && $0.action == "sell" && $0.at >= entry.at
            }) else { continue }
            current.entries[i].costs = tradingCosts(entry: entry, sell: sell, in: state.trades)
            changed = true
        }

        // A session that is over keeps its verdict. Only the accounting is refreshed.
        guard current.status == .running else {
            if changed { save(current) }
            return current
        }

        // --- entries whose position has gone: find the close and record it.
        for i in current.entries.indices where current.entries[i].closedAt == nil {
            let entry = current.entries[i]
            let stillOpen = state.positions.contains { $0.symbol == entry.symbol }
            guard !stillOpen else { continue }
            guard let sell = state.trades.first(where: {
                $0.symbol == entry.symbol && $0.action == "sell" && $0.at >= entry.at
            }) else { continue }
            current.entries[i].closedAt = sell.at
            current.entries[i].exit = sell.price
            current.entries[i].pnl = sell.pnl
            current.entries[i].rMultiple = sell.rMultiple
            current.entries[i].trigger = sell.trigger
            current.entries[i].costs = tradingCosts(entry: entry, sell: sell, in: state.trades)
            changed = true
        }

        // --- what the still-open session positions are worth right now.
        let openSymbols = Set(current.entries.filter { $0.closedAt == nil }.map(\.symbol))
        let valued = led.value(priced)
        let unrealised = valued.positions
            .filter { openSymbols.contains($0.symbol) }
            .reduce(0.0) { $0 + $1.pnl }

        // --- the three rules.
        if let (status, note) = SessionEngine.verdict(current, unrealised: unrealised) {
            current.status = status
            current.endedAt = nowMs()
            current.endNote = note
            changed = true

            // Flat at the end. Deliberately after the verdict is recorded, so the
            // session's own note explains the closes rather than them appearing
            // unexplained in the journal.
            if current.flatAtEnd {
                for symbol in openSymbols {
                    let result = led.sell(symbol: symbol, shares: nil,
                                          mark: priced[symbol] ?? mark(symbol, b)!,
                                          reason: "Session ended: \(status.label.lowercased()). Positions opened by a session are closed when it ends.",
                                          trigger: "session")
                    if case .failed(let why) = result { log("[session] could not flatten \(symbol): \(why)", .warn, "session") }
                }
                // Pick the closes up in the same pass so the report is complete.
                for i in current.entries.indices where current.entries[i].closedAt == nil {
                    if let sell = led.state.trades.first(where: {
                        $0.symbol == current.entries[i].symbol && $0.action == "sell" && $0.at >= current.entries[i].at
                    }) {
                        current.entries[i].closedAt = sell.at
                        current.entries[i].exit = sell.price
                        current.entries[i].pnl = sell.pnl
                        current.entries[i].rMultiple = sell.rMultiple
                        current.entries[i].trigger = sell.trigger
                        current.entries[i].costs = tradingCosts(entry: current.entries[i],
                                                                sell: sell, in: led.state.trades)
                    }
                }
            }
            log("[session] \(status.rawValue): \(note)")
        }

        if changed { save(current) }
        return current
    }

    /**
     * Everything one round trip paid: the spread crossed on the way in and again on
     * the way out, plus commission on both.
     *
     * Reconstructed from the ledger's own fills rather than estimated, because on a
     * five-minute timeframe the costs are routinely larger than the price move that
     * the trade was actually about, and an estimate would be arguing rather than
     * reporting.
     */
    private func tradingCosts(entry: SessionEntry, sell: Trade, in trades: [Trade]) -> Double {
        let buy = trades.first {
            $0.symbol == entry.symbol && $0.action == "buy" && abs($0.at - entry.at) < 1_000
        }
        return (buy?.commission ?? 0) + (buy?.slippage ?? 0) + sell.commission + sell.slippage
    }

    /**
     * Said when the stake, rather than the risk rule, decided the position size.
     *
     * An intraday stop can sit a fifth of a percent away, and risking the session's
     * full per-trade budget at that distance would need a position several times the
     * stake. There is no margin here, so the stake wins and the trade risks less than
     * the rule allows. Explaining that is the point — "why is this risking $5 when I
     * said $50" is the question that teaches what leverage actually is and why the
     * people who use it get carried out.
     */
    private func sizeNote(_ plan: Analysis.TradePlan, session: TradingSession, symbol: String) -> String? {
        guard plan.sizedBy == .concentration, plan.riskTaken < session.riskPerTrade * 0.9,
              plan.entry > 0, plan.entry > plan.stop else { return nil }
        let stopFraction = (plan.entry - plan.stop) / plan.entry
        let wouldNeed = session.riskPerTrade / Swift.max(stopFraction, 0.00001)
        return "The stake decided this size, not the risk rule. \(symbol)'s stop is "
            + "\(f(stopFraction * 100, 2))% away, so risking the full \(money(session.riskPerTrade)) "
            + "would need a \(money(wouldNeed)) position, more than this session holds. There is no "
            + "margin here, so the stake caps it and this risks \(money(plan.riskTaken)) instead."
    }

    /// The whole session tab, scanned fresh.
    private func sessionPanel(_ profile: Profile, board b: Board) async -> SessionPanel {
        // "Open" for a board spanning two exchanges means any of them, not New York.
        let marketOpen = profile.activeVenues.contains { MarketCalendar.isSessionOpen(venue: $0) }
        let current = refreshSession(profile, board: b)
        let led = ledger(for: profile)
        let valued = led.value(marks(b))

        guard let live = current else {
            return SessionPanel(
                session: nil, status: "none", realised: 0, unrealised: 0, total: 0, totalPct: 0,
                secondsLeft: 0, lossLimit: 0, lossHeadroom: 0, targetAmount: 0,
                dayTradesLeft: PDT.remaining(equity: valued.equity, records: led.state.dayTrades,
                                             frictions: profile.frictions),
                candidates: [], openSymbols: [], barsAt: 0, marketOpen: marketOpen,
                note: SessionEngine.note(nil, marketOpen: marketOpen)
            )
        }

        let openSymbols = live.entries.filter { $0.closedAt == nil }.map(\.symbol)
        let unrealised = valued.positions
            .filter { openSymbols.contains($0.symbol) }
            .reduce(0.0) { $0 + $1.pnl }
        let openRisk = valued.positions
            .filter { openSymbols.contains($0.symbol) }
            .reduce(0.0) { $0 + ($1.openRisk ?? 0) }
        let dayTradesLeft = PDT.remaining(equity: valued.equity, records: led.state.dayTrades,
                                          frictions: profile.frictions)

        // Scanning stops when the session does. A closed session that keeps pulling
        // intraday bars every twenty seconds is spending requests on a board nobody
        // may trade from.
        var candidates: [SessionCandidate] = []
        var barsAt: Double = 0
        if live.status == .running {
            let symbols = SessionEngine.universe(for: profile)
            let bars = await intradayBars(symbols)
            barsAt = nowMs()
            let rules = live.sizingRules()

            for symbol in symbols {
                guard let series = bars[symbol], series.count >= 60 else { continue }
                let quote = b.quotes[symbol]
                let m = Analysis.analyse(symbol, series, livePrice: quote?.price)
                let plan = Analysis.buildPlan(m, rules)
                let inst = Universe.bySymbol[symbol]
                candidates.append(SessionCandidate(
                    symbol: symbol, name: inst?.name ?? symbol,
                    price: m.price, changePct: quote?.changePct ?? 0,
                    plan: plan, conviction: m.conviction, regime: m.regime.rawValue,
                    barRangePct: m.atrPct, barsToTarget: plan.horizonDays,
                    sizeNote: sizeNote(plan, session: live, symbol: symbol),
                    blocked: SessionEngine.blocker(
                        live, plan: plan, symbol: symbol,
                        held: openSymbols.contains(symbol), openRisk: openRisk,
                        dayTradesLeft: dayTradesLeft
                    )
                ))
            }
            // Tradable first, then by the engine's read.
            candidates.sort {
                ($0.blocked == nil ? 0 : 1, -$0.conviction) < ($1.blocked == nil ? 0 : 1, -$1.conviction)
            }
        }

        let total = live.realised + unrealised
        return SessionPanel(
            session: live, status: live.status.rawValue,
            realised: live.realised, unrealised: unrealised, total: total,
            totalPct: live.stake > 0 ? total / live.stake * 100 : 0,
            secondsLeft: live.secondsLeft,
            lossLimit: live.lossLimit,
            lossHeadroom: Swift.max(0, live.lossLimit + Swift.min(0, total)),
            targetAmount: live.targetAmount,
            dayTradesLeft: dayTradesLeft,
            candidates: candidates, openSymbols: openSymbols,
            barsAt: barsAt, marketOpen: marketOpen,
            note: SessionEngine.note(live, marketOpen: marketOpen)
        )
    }

    /**
     * Files what was recommended, so a later review can ask what the market made of
     * it. The funded picks are recorded when there is a ranking; without one the
     * whole eligible candidate set is, because the engine's shortlist is still a
     * claim about the market and still worth grading.
     */
    private func recordRun(profile: Profile, candidates: [Candidate],
                           ranking: RankOutput?, board: Board) {
        var m = memory(for: profile.id)
        let allocation = Dictionary(
            (ranking?.picks ?? []).map { ($0.symbol, $0.allocationPct) },
            uniquingKeysWith: { a, _ in a }
        )
        let funded = Set(allocation.keys)
        let subject = funded.isEmpty ? candidates : candidates.filter { funded.contains($0.metrics.symbol) }

        let picks: [RunPick] = subject.map { c in
            RunPick(
                symbol: c.metrics.symbol,
                sector: Universe.bySymbol[c.metrics.symbol]?.sector ?? "Unknown",
                regime: c.metrics.regime.rawValue,
                conviction: c.learnedConviction ?? c.metrics.conviction,
                entry: c.plan.entry, target: c.plan.target, stop: c.plan.stop,
                rr: c.plan.rr, horizonDays: c.plan.horizonDays,
                atrPct: c.metrics.atrPct,
                allocationPct: allocation[c.metrics.symbol] ?? 0
            )
        }
        guard !picks.isEmpty else { return }

        m.runs.insert(RunRecord(
            id: UUID().uuidString, at: nowMs(), profileId: profile.id,
            calibration: m.calibration, lessonIds: m.applied.map(\.id),
            picks: picks, outcomes: [], gradedAt: nil
        ), at: 0)
        // Forty runs is more history than any lesson looks at, and it keeps the file
        // small enough to stay readable by a person.
        if m.runs.count > 40 { m.runs = Array(m.runs.prefix(40)) }
        m.analysesRun += 1
        for i in m.lessons.indices where m.lessons[i].status == .applied {
            m.lessons[i].runsSinceApplied += 1
        }
        save(m)
    }

    /* --------------------------------------------------------- the review run */

    /// The forensics. Pure arithmetic over price history, so this runs on every
    /// request and costs nothing — the paid pass only writes the words about it.
    private func forensics(_ b: Board, _ profile: Profile) -> (reviews: [TradeReview], behaviour: BehaviourReport) {
        let led = ledger(for: profile)
        let state = led.state
        let pairs = Review.pairs(state.trades)

        let reviews: [TradeReview] = pairs.reversed().compactMap { pair in
            guard let bars = b.bars[pair.sell.symbol] else { return nil }
            // The stop the position carried, recovered from the trade's own R
            // multiple now that the position itself is gone.
            var stop: Double?
            if let r = pair.sell.rMultiple, r != 0 {
                let move = pair.sell.price - pair.entry
                if move != 0 { stop = pair.entry - move / r }
            }
            return Review.build(sell: pair.sell, openedAt: pair.openedAt, entry: pair.entry,
                                stop: stop, target: nil, thesis: pair.sell.reason, bars: bars)
        }

        // Account against simply owning the index over the same window.
        var benchmarkPct: Double?
        if let first = state.equityCurve.first, let spy = b.bars["SPY"],
           let then = spy.last(where: { $0.t <= first.t })?.c ?? spy.first?.c,
           let now = spy.last?.c, then > 0 {
            benchmarkPct = ((now - then) / then) * 100
        }
        let v = led.value(marks(b))
        let paidIn = state.startingCapital + state.totalContributed
        let accountPct = paidIn > 0 ? (v.netOfContributions / paidIn) * 100 : nil

        let behaviour = Review.behaviour(reviews, state: state,
                                         accountReturnPct: accountPct,
                                         benchmarkReturnPct: benchmarkPct)
        return (reviews, behaviour)
    }

    private func startReview() {
        let profile = activeProfile
        job = AnalysisJob(status: "running", kind: "review", stage: nil,
                          startedAt: nowMs(), finishedAt: 0, error: nil, candidates: 0)
        analysisTask = Task {
            let b = await self.getBoard()
            let led = self.ledger(for: profile)
            let (reviews, behaviour) = self.forensics(b, profile)
            self.noteCandidateCount(reviews.count)

            // No closed trades is not nothing to learn from. Every recommendation this
            // desk has already made has an answer by now, whether or not it was traded,
            // so the grading and the engine's own lessons still run — which is the case
            // that matters most for someone who has not risked anything yet.
            guard !reviews.isEmpty else {
                self.write(CachedReview(at: nowMs(), profileId: profile.id, notes: [], report: nil,
                                        passes: ["no-closed-trades"], engineOnly: true), to: self.reviewURL)
                self.setStage(.learning)
                let gov = self.openGovernor(kind: "review")
                let learned = await self.learn(profile: profile, board: b, reviews: [],
                                               behaviour: behaviour, scorecard: led.scorecard(),
                                               governor: gov)
                await self.settle(gov)
                self.finishJob()
                log("[analyst] review run finished — no closed trades\(learned > 0 ? ", learn:\(learned)" : ", nothing to learn yet")")
                return
            }

            var newsBySymbol: [String: [Headline]] = [:]
            let symbols = Set(reviews.prefix(12).map(\.symbol))
            await withTaskGroup(of: (String, [Headline]).self) { group in
                for sym in symbols {
                    group.addTask { (sym, (try? await Market.shared.headlines(sym, count: 6)) ?? []) }
                }
                for await (sym, news) in group { newsBySymbol[sym] = news }
            }

            let brief = self.memoryBrief(profile)
            let gov = self.openGovernor(kind: "review")
            let result = await Analyst.runReview(
                reviews, behaviour, led.scorecard(), led.taxSummary(), profile,
                b.regimes.all, news: newsBySymbol,
                memory: brief, governor: gov
            ) { stage in
                Task { self.setStage(stage) }
            }

            self.write(CachedReview(
                at: nowMs(), profileId: profile.id, notes: result.notes, report: result.report,
                passes: result.passes, engineOnly: !Analyst.available()
            ), to: self.reviewURL)

            // The learning pass runs last and on its own terms: it reads the same
            // record the review just wrote about, plus the grading of every past
            // recommendation, and produces proposals rather than changes.
            self.setStage(.learning)
            let learned = await self.learn(profile: profile, board: b, reviews: reviews,
                                           behaviour: behaviour, scorecard: led.scorecard(),
                                           governor: gov)
            await self.settle(gov)
            self.finishJob()
            log("[analyst] review run finished — \(result.passes.joined(separator: " → "))\(learned > 0 ? " → learn:\(learned)" : "")")
        }
    }

    /**
     * Grade, derive, propose.
     *
     * Three steps, deliberately in this order and deliberately separable: the
     * grading is arithmetic over bars and always runs; the arithmetic rules always
     * run; only the third step needs a key, and losing it costs the interpretation
     * rather than the findings.
     */
    private func learn(profile: Profile, board b: Board, reviews: [TradeReview],
                       behaviour: BehaviourReport, scorecard: Scorecard,
                       governor: Governor? = nil) async -> Int {
        var m = memory(for: profile.id)

        // 1. What did the market make of what we recommended?
        m.runs = Learning.gradeRuns(m.runs, bars: b.bars)

        // 2. What the arithmetic can conclude on its own.
        var fresh = Learning.engineLessons(m.runs, current: m.calibration)
        fresh += Learning.behaviourLessons(reviews, behaviour, scorecard, profile, current: m.calibration)
        Learning.merge(fresh, into: &m)
        save(m)

        // 3. What Claude can see that the rules cannot. Its proposals join the same
        //    queue, clamped by the same bounds, needing the same approval.
        guard Analyst.available() else { return m.open.count }
        let (proposed, note) = await Analyst.proposeLessons(
            runs: m.runs, behaviour: behaviour, scorecard: scorecard,
            memory: m, profile: profile, alreadyFound: m.lessons, governor: governor
        )
        if let note { notYetSupported[profile.id] = note }
        if !proposed.isEmpty {
            Learning.merge(proposed, into: &m)
            save(m)
        }
        return m.open.count
    }

    /// Re-scores every past recommendation against the current bars. Idempotent, and
    /// only writes when something actually changed.
    private func regrade(_ profile: Profile, board b: Board) {
        var m = memory(for: profile.id)
        guard !m.runs.isEmpty else { return }
        let before = m.runs.reduce(0) { $0 + $1.outcomes.count }
        m.runs = Learning.gradeRuns(m.runs, bars: b.bars)
        let after = m.runs.reduce(0) { $0 + $1.outcomes.count }
        guard after != before else { return }
        save(m)
    }

    /// The engine's own record as one number, computed fresh from the graded runs.
    private func scoreboard(_ profile: Profile) -> EngineScoreboard {
        let m = memory(for: profile.id)
        let led = ledger(for: profile)
        let outcomes = m.runs.flatMap(\.outcomes)
        guard !outcomes.isEmpty else {
            return EngineScoreboard(
                graded: 0, resolved: 0, hitTarget: 0, hitStop: 0,
                recoveredAfterStop: 0, ranOnAfterTarget: 0, avgR: nil,
                takenAvgR: nil, untakenAvgR: nil,
                verdict: "No recommendation is old enough to have an answer yet. Each needs at least three sessions of price history after the run before it counts, so this fills in over the following days."
            )
        }

        // Which recommendations were actually funded, so the engine's picks and the
        // user's choices can be told apart.
        let traded = Set(led.state.trades.filter { $0.action == "buy" }.map(\.symbol))
        let rs = outcomes.compactMap(\.rMultiple)
        let takenRs = outcomes.filter { traded.contains($0.symbol) }.compactMap(\.rMultiple)
        let untakenRs = outcomes.filter { !traded.contains($0.symbol) }.compactMap(\.rMultiple)
        func avg(_ xs: [Double]) -> Double? { xs.isEmpty ? nil : xs.reduce(0, +) / Double(xs.count) }

        let resolved = outcomes.filter(\.resolved).count
        let hitStop = outcomes.filter(\.hitStop).count
        let recovered = outcomes.filter(\.recoveredAfterStop).count
        let avgR = avg(rs)

        let hitTarget = outcomes.filter(\.hitTarget).count
        var verdict = ""

        if outcomes.count < 6 {
            let plural = outcomes.count == 1 ? "" : "s"
            verdict = "\(outcomes.count) recommendation\(plural) graded so far, too few to read anything into. "
            verdict += "The average becomes meaningful at a couple of dozen."
        } else if let avgR {
            verdict = "Across \(outcomes.count) graded recommendations the engine's own picks have returned "
            verdict += "\(f(avgR, 2))R on average"
            if resolved > 0 {
                verdict += ", with \(hitTarget) reaching their target and \(hitStop) hitting their stop"
            }
            verdict += "."

            if hitStop >= 4 {
                let rate = Double(recovered) / Double(hitStop) * 100
                verdict += " \(f(rate, 0))% of the stop-outs recovered above their entry afterwards"
                verdict += rate >= 40
                    ? ", which indicates stops placed inside the ordinary noise."
                    : ", which is the rate correctly placed stops produce."
            }

            if takenRs.count >= 3, untakenRs.count >= 3, let t = avg(takenRs), let u = avg(untakenRs) {
                let pair = "\(f(t, 2))R against \(f(u, 2))R for the ones you passed on"
                if t < u - 0.3 {
                    verdict += " The ones you funded returned \(pair), so the selection is costing more than the engine."
                } else if t > u + 0.3 {
                    verdict += " The ones you funded returned \(pair), so your selection is adding something."
                } else {
                    verdict += " Funded and passed-over picks performed about the same, so the selection between them is not yet making a difference."
                }
            }
        } else {
            verdict = "\(outcomes.count) recommendations graded, none with a computable result yet."
        }

        return EngineScoreboard(
            graded: outcomes.count, resolved: resolved,
            hitTarget: hitTarget, hitStop: hitStop,
            recoveredAfterStop: recovered,
            ranOnAfterTarget: outcomes.filter(\.ranOnAfterTarget).count,
            avgR: avgR, takenAvgR: avg(takenRs), untakenAvgR: avg(untakenRs),
            verdict: verdict
        )
    }

    /* -------------------------------------------------------------- the routes */

    func handle(_ req: HTTPRequest) async -> HTTPResponse {
        do {
            return try await route(req)
        } catch {
            log("[error] \(error.localizedDescription)", .error, "analyst")
            return .error(error.localizedDescription, status: 500)
        }
    }

    private func route(_ req: HTTPRequest) async throws -> HTTPResponse {
        let p = req.path

        /* --- read side ------------------------------------------------------- */

        if p == "/api/state" {
            let b = await getBoard(force: req.query("force") == "1")
            return .encoded(stateResponse(b))
        }

        if p == "/api/markets" {
            let b = await getBoard()
            let profile = activeProfile
            let rules = sizing(b, profile)
            let rows = Universe.all.compactMap { inst -> MarketRow? in
                guard let m = b.metrics[inst.symbol] else { return nil }
                return MarketRow(
                    symbol: inst.symbol, name: inst.name, klass: inst.klass,
                    sector: inst.sector, note: inst.note,
                    benchmark: Universe.benchmarks.contains(inst.symbol),
                    quote: b.quotes[inst.symbol],
                    metrics: m,
                    plan: Analysis.buildPlan(m, rules),
                    inUniverse: profile.allows(inst.symbol),
                    venue: inst.venue,
                    currency: inst.currency.code,
                    marketOpen: MarketCalendar.isSessionOpen(venue: inst.venue)
                )
            }
            return .encoded(MarketsResponse(rows: rows, regimes: b.regimes, asOf: b.at,
                                            pricesAt: b.pricesAt, barsAt: b.barsAt))
        }

        if p.hasPrefix("/api/instrument/") {
            let raw = String(p.dropFirst("/api/instrument/".count))
            let sym = raw.removingPercentEncoding ?? raw
            guard let inst = Universe.bySymbol[sym] else { return .error("Unknown symbol.", status: 404) }
            let b = await getBoard()
            let profile = activeProfile
            let range = req.query("range") ?? "6mo"
            let chart = try await Market.shared.chart(sym, range: range, interval: "1d")
            let m = b.metrics[sym] ?? Analysis.analyse(sym, chart.bars)
            let news = (try? await Market.shared.headlines(sym, count: 6)) ?? []
            return .encoded(InstrumentResponse(
                instrument: inst, quote: b.quotes[sym], metrics: m,
                plan: Analysis.buildPlan(m, sizing(b, profile)),
                bars: chart.bars, news: news, inUniverse: profile.allows(sym)
            ))
        }

        /* What the engine would look at, for a horizon, without calling anything.
         * Free, instant, and the answer to "would this even be different?". */
        if p == "/api/shortlist" {
            let b = await getBoard()
            let profile = activeProfile
            let horizon = req.query("style").flatMap(TimeHorizon.init(rawValue:)) ?? profile.horizon
            let list = candidates(b, profile, style: horizon)
            let picks: [ShortlistPick] = list.picks.map { c in
                let inst = Universe.bySymbol[c.metrics.symbol]
                return ShortlistPick(
                    symbol: c.metrics.symbol,
                    name: inst?.name ?? c.metrics.symbol,
                    sector: inst?.sector ?? "n/a",
                    venue: (inst?.venue ?? .us).label,
                    currency: Universe.currency(of: c.metrics.symbol).code,
                    conviction: c.learnedConviction ?? c.metrics.conviction,
                    rawConviction: c.metrics.conviction,
                    regime: c.metrics.regime.rawValue,
                    rr: c.plan.rr,
                    entry: c.plan.entry,
                    stop: c.plan.stop,
                    target: c.plan.target,
                    scores: c.metrics.scores
                )
            }
            return .encoded(ShortlistResponse(
                style: horizon.rawValue,
                label: horizon.label,
                emphasis: horizon.emphasis,
                considered: list.considered,
                picks: picks,
                nearMisses: list.nearMisses
            ))
        }

        if p == "/api/analysis" {
            let liveJob = await jobSnapshot()
            let cached = readAnalysisCache()
            // A run belonging to another profile is not this profile's analysis.
            let mine = cached?.profileId == activeProfile.id ? cached : nil
            // Spelled out one local at a time. Inlined, the optional chains and the
            // defaults made one expression the type checker would not finish.
            let at: Double = mine?.at ?? 0
            let reads: [ScreenRead] = mine?.reads ?? []
            let briefs: [BriefOut] = mine?.briefs ?? []
            let plans: [String: Analysis.TradePlan] = mine?.plans ?? [:]
            let metrics: [String: Analysis.Metrics] = mine?.metrics ?? [:]
            let ms: Double = mine?.ms ?? 0
            let passes: [String] = mine?.passes ?? []
            let engineOnly: Bool = mine?.engineOnly ?? !Analyst.available()
            let style: String = mine?.style ?? activeProfile.horizon.rawValue
            let nearMisses: [NearMiss] = mine?.nearMisses ?? []
            let considered: Int = mine?.considered ?? 0
            let styles: [StyleOption] = TimeHorizon.allCases.map(StyleOption.init)
            return .encoded(AnalysisResponse(
                at: at, reads: reads, ranking: mine?.ranking,
                briefs: briefs, plans: plans, metrics: metrics,
                ms: ms, passes: passes,
                engineOnly: engineOnly, job: liveJob,
                diagnosis: lastRun?.diagnosis,
                style: style, nearMisses: nearMisses, considered: considered,
                styles: styles
            ))
        }

        if p == "/api/review", req.method != "POST" {
            let liveJob = await jobSnapshot()
            let b = await getBoard()
            let profile = activeProfile
            let (reviews, behaviour) = forensics(b, profile)
            let cached = readReviewCache()
            let mine = cached?.profileId == profile.id ? cached : nil
            return .encoded(ReviewResponse(
                reviews: reviews.reversed(), behaviour: behaviour,
                tax: ledger(for: profile).taxSummary(),
                at: mine?.at ?? 0, notes: mine?.notes ?? [], report: mine?.report,
                passes: mine?.passes ?? [], engineOnly: mine?.engineOnly ?? !Analyst.available(),
                job: liveJob, diagnosis: lastRun?.diagnosis
            ))
        }

        if p == "/api/scorecard" { return .encoded(ledger.scorecard()) }

        /* What happened to this account while Paper was shut. Surfaced rather than
         * applied silently: reconstructed exits are a weaker claim than observed
         * ones, and the principal should see the ones that were taken on their
         * behalf before the equity curve simply reads differently one morning. */
        if p == "/api/reconciliation" {
            // The board build is what runs the replay, so ask for it first — otherwise
            // this endpoint reports "nothing happened" purely because nothing has
            // looked yet.
            _ = await getBoard()
            // An empty object rather than a null: a top-level nil does not encode, and
            // "no catch-up to report" is a normal answer, not an error.
            guard let report = reconciliation(for: activeProfile.id) else { return .json([:]) }
            return .encoded(report)
        }

        if p == "/api/reconciliation/ack", req.method == "POST" {
            acknowledgeReconciliation(activeProfile.id)
            return .encoded(["ok": true])
        }

        /* --- the analyst runs -------------------------------------------------- */

        if p == "/api/analyse", req.method == "POST" {
            if job.status == "running" { return .json(["started": false, "job": encodeJob()]) }
            // An unknown style falls back to the profile's own horizon rather than
            // failing the request: the worst case is the run the button always did.
            let style = req.query("style").flatMap(TimeHorizon.init(rawValue:))
            startAnalysis(style: style)
            return .json(["started": true, "job": encodeJob()])
        }

        if p == "/api/review", req.method == "POST" {
            if job.status == "running" { return .json(["started": false, "job": encodeJob()]) }
            startReview()
            return .json(["started": true, "job": encodeJob()])
        }

        if p.hasPrefix("/api/explain/"), req.method == "POST" {
            let raw = String(p.dropFirst("/api/explain/".count))
            let sym = raw.removingPercentEncoding ?? raw
            guard Universe.bySymbol[sym] != nil else { return .error("Unknown symbol.", status: 404) }
            let b = await getBoard()
            let profile = activeProfile
            guard let m = b.metrics[sym] else {
                return .error("No market data for that symbol right now.", status: 503)
            }
            let news = (try? await Market.shared.headlines(sym, count: 5)) ?? []
            let cand = Candidate(metrics: m, plan: Analysis.buildPlan(m, sizing(b, profile)), news: news)
            let brief = await Analyst.explainOne(cand, b.regimes.all, profile)
            return .encoded(ExplainResponse(brief: brief, plan: cand.plan, metrics: m, available: Analyst.available()))
        }

        /* --- the analyst: credentials, budget, and what a run cost ------------- */

        if p == "/api/analyst" {
            let b = await getBoard()
            let age = b.pricesAt > 0 ? Int((nowMs() - b.pricesAt) / 1000) : nil
            let price = ModelPrice.of(Analyst.model)
            let main = ModelCatalogue.describe(Analyst.model)
            let fast = AnalystModel.currentFast.map { ModelCatalogue.describe($0) }
            let base = ModelCatalogue.fallback

            /* How much of a run the mechanical passes actually account for.
             *
             * Measured from the last run where there is one, rather than assumed. The
             * share swings with how many candidates clear the engine — four candidates
             * is one screening batch and a quarter of the tokens, twelve is three
             * batches and rather more — and quoting a saving from a guess would make
             * this figure the one thing on the panel that is not from the record. */
            let mechanicalShare: Double = {
                guard let last = lastRun, last.billedTokens > 0 else { return 0.3 }
                let mechanical = last.calls
                    .filter { ModelCatalogue.mechanicalPasses.contains($0.pass) }
                    .reduce(0) { $0 + $1.billedTokens }
                return Analysis.clamp(Double(mechanical) / Double(last.billedTokens), 0.05, 0.7)
            }()
            let relative = fast == nil
                ? main.costVersus(base)
                : main.costVersus(base) * (1 - mechanicalShare) + fast!.costVersus(base) * mechanicalShare

            return .encoded(AnalystPanel(
                credentials: Credentials.status(),
                model: Analyst.model,
                modelPriced: price != nil,
                inputPerMTok: price?.inputPerMTok,
                outputPerMTok: price?.outputPerMTok,
                limits: settings.analystLimits,
                lastRun: lastRun,
                selfCheck: Diagnostics.selfCheck(
                    dataDirectory: Desk.dataDirectory, model: Analyst.model,
                    lastRun: lastRun,
                    marketFresh: age != nil && age! < 600,
                    marketAgeSeconds: age
                ),
                models: ModelCatalogue.all,
                modelSource: AnalystModel.source,
                fastModel: AnalystModel.currentFast,
                mechanicalPasses: ModelCatalogue.mechanicalPasses.sorted(),
                relativeCost: relative
            ))
        }

        /**
         * Saving a key verifies it first. Persisting an unverified one reports the app
         * as configured, fails every analysis, and surfaces the error three screens
         * from the field that caused it.
         *
         * The key itself is never echoed back — the response carries a fingerprint.
         */
        if p == "/api/analyst/key", req.method == "POST" {
            guard let key = req.json["key"] as? String, !key.trimmingCharacters(in: .whitespaces).isEmpty else {
                return .error("No key was sent.", status: 400)
            }
            switch await Credentials.check(key, model: Analyst.model) {
            case .ok:
                guard Credentials.writeKeychain(key.trimmingCharacters(in: .whitespacesAndNewlines)) else {
                    return .error("The key works, but macOS refused to write it to the Keychain. This usually means a permissions prompt was dismissed. Try again and allow it.", status: 500)
                }
                log("[analyst] a key was saved to the Keychain (\(Credentials.fingerprint(key)))")
                return .encoded(Credentials.status())
            case .rejected(let why):
                return .error(why, status: 400)
            case .unavailable(let why):
                return .error(why, status: 503)
            }
        }

        /// Tests whatever key is currently in force, wherever it came from.
        if p == "/api/analyst/test", req.method == "POST" {
            guard let resolved = Credentials.resolve() else {
                return .error("There is no key to test. Paste one first.", status: 400)
            }
            switch await Credentials.check(resolved.key, model: Analyst.model) {
            case .ok(let model):
                return .json(["ok": true, "model": model, "source": resolved.source.rawValue,
                              "note": "One request went out and came back. The key works and the model is available on this account."])
            case .rejected(let why):
                return .json(["ok": false, "note": why])
            case .unavailable(let why):
                return .json(["ok": false, "transient": true, "note": why])
            }
        }

        if p == "/api/analyst/key", req.method == "DELETE" {
            _ = Credentials.deleteKeychain()
            return .encoded(Credentials.status())
        }

        /**
         * The model picker.
         *
         * An unknown id is refused rather than saved: the failure would otherwise be a
         * 404 on the first pass of the next analysis, several screens away from the
         * control that caused it, and after the run had already been paid for.
         */
        if p == "/api/analyst/model", req.method == "POST" {
            let main = (req.json["model"] as? String ?? "").trimmingCharacters(in: .whitespaces)
            let fast = (req.json["fastModel"] as? String ?? "").trimmingCharacters(in: .whitespaces)

            if !main.isEmpty, ModelCatalogue.of(main) == nil {
                return .error("Paper does not know the model \"\(main)\". Pick one from the list; an unchecked id would fail on the first pass of the next analysis, after the run had been billed.", status: 400)
            }
            if !fast.isEmpty, ModelCatalogue.of(fast) == nil {
                return .error("Paper does not know the model \"\(fast)\".", status: 400)
            }
            // A cheaper model for the mechanical passes only makes sense if it is
            // actually cheaper; the same model in both slots is just the one model.
            let resolvedFast = fast == main ? "" : fast

            settings.analystModel = main
            settings.analystFastModel = resolvedFast
            persistSettings()
            AnalystModel.adopt(main: main, fast: resolvedFast)
            log("[analyst] model set to \(Analyst.model)" + (resolvedFast.isEmpty ? "" : ", screening on \(resolvedFast)"))
            return .json(["model": Analyst.model, "fastModel": resolvedFast, "source": AnalystModel.source])
        }

        if p == "/api/analyst/limits", req.method == "POST" {
            guard let incoming = decode(RunLimits.self, req.json) else {
                return .error("Those limits could not be read.", status: 400)
            }
            settings.analystLimits = incoming.sanitised()
            persistSettings()
            return .encoded(settings.analystLimits)
        }

        /// Free, local, and deliberately independent of the API — the point of this
        /// button is that it works when the API is the thing that is broken.
        if p == "/api/analyst/check" {
            let b = await getBoard()
            let age = b.pricesAt > 0 ? Int((nowMs() - b.pricesAt) / 1000) : nil
            return .encoded(Diagnostics.selfCheck(
                dataDirectory: Desk.dataDirectory, model: Analyst.model,
                lastRun: lastRun,
                marketFresh: age != nil && age! < 600,
                marketAgeSeconds: age
            ))
        }

        /**
         * The app's own log, read back without leaving the app.
         *
         * A bundled `.app` launched from Finder writes its standard error into a
         * stream nobody has open, which meant every line about a stale price, a
         * refused write or a bracket that fired while the window sat behind a
         * browser was emitted and lost. Now it goes to a dated file — and this is
         * the route that shows it, because a diagnostic you have to know about
         * Console.app to read is one that gets read after the incident rather than
         * during it.
         */
        if p == "/api/logs" {
            let level = LogLevel(rawValue: req.query("level") ?? "") ?? .debug
            let subsystem = req.query("subsystem").flatMap { $0.isEmpty ? nil : $0 }
            let limit = Int(req.query("limit") ?? "") ?? 400
            return .json([
                "entries": Log.recent(limit: Swift.min(limit, Log.bufferSize),
                                      level: level, subsystem: subsystem).map {
                    ["id": $0.id, "at": $0.at, "level": $0.level.rawValue,
                     "subsystem": $0.subsystem, "message": $0.message]
                },
                "subsystems": Log.subsystems(),
                "levels": LogLevel.allCases.map(\.rawValue),
                "tally": Log.tally(),
                "threshold": Log.thresholdName,
                "files": Log.files(),
                "directory": Log.directory.path,
                "retainDays": Log.retainDays,
                // The ledgers that have gone read-only, and the memories that have.
                // They belong on the same screen as the log: they are the two things
                // that are silently wrong rather than visibly broken.
                "ledgerErrors": profiles.compactMap { pr -> [String: String]? in
                    guard let e = ledger(for: pr).loadError else { return nil }
                    return ["profile": pr.name, "error": e]
                },
                "memoryErrors": profiles.compactMap { pr -> [String: String]? in
                    guard let e = memoryError(for: pr.id) else { return nil }
                    return ["profile": pr.name, "error": e]
                },
            ])
        }

        /// Lowering the floor without a rebuild, for a problem that only appears in
        /// a built app.
        if p == "/api/logs/level", req.method == "POST" {
            guard let raw = req.json["level"] as? String, let level = LogLevel(rawValue: raw) else {
                return .error("Unknown log level. One of: \(LogLevel.allCases.map(\.rawValue).joined(separator: ", ")).", status: 400)
            }
            Log.setThreshold(level)
            return .json(["ok": true, "threshold": level.rawValue])
        }

        if p == "/api/analyse/stop", req.method == "POST" {
            guard let governor, job.status == "running" else {
                return .json(["stopped": false, "note": "Nothing is running."])
            }
            await governor.cancel()
            return .json(["stopped": true,
                          "note": "Stopping. Calls already in flight still finish and are still billed."])
        }

        /* --- the day-trading session ------------------------------------------- */

        if p == "/api/session" {
            let b = await getBoard()
            return .encoded(await sessionPanel(activeProfile, board: b))
        }

        if p == "/api/session/start", req.method == "POST" {
            let profile = activeProfile
            let b = await getBoard()
            // Refreshed before the guard, not after. A session whose clock ran out while
            // the app was closed still has `running` on disk, and testing the stored
            // status would refuse a new session until something else happened to look
            // at the old one.
            if let running = refreshSession(profile, board: b), running.status == .running {
                return .error("A session is already running on this account. End it before starting another; overlapping sessions would each measure a P/L the other caused.", status: 400)
            }
            let led = ledger(for: profile)
            let equity = led.value(marks(b)).equity
            let cash = led.value(marks(b)).cash

            let stake = num(req.json["stake"]) ?? 0
            let minutes = num(req.json["minutes"]) ?? 60
            guard stake > 0 else { return .error("A session needs an amount to trade.", status: 400) }
            guard stake <= cash else {
                return .error("There is \(money(cash)) in cash and the session asked for \(money(stake)). A session can only commit cash that is free; the rest is in open positions.", status: 400)
            }
            guard minutes >= 5, minutes <= 480 else {
                return .error("A session runs between five minutes and eight hours.", status: 400)
            }

            var fresh = TradingSession.opening(
                profile: profile, stake: stake, minutes: minutes, equity: equity,
                maxLossPct: Analysis.clamp(num(req.json["maxLossPct"]) ?? 3, 0.5, 25),
                targetPct: Analysis.clamp(num(req.json["targetPct"]) ?? 5, 0.5, 50),
                riskPctPerTrade: Analysis.clamp(num(req.json["riskPctPerTrade"]) ?? 1, 0.1, 5),
                maxTrades: Int(Analysis.clamp(num(req.json["maxTrades"]) ?? 6, 1, 20)),
                flatAtEnd: req.json["flatAtEnd"] as? Bool ?? true
            )
            // A target below the loss limit is a session that can only end badly, and a
            // typo rather than an intention.
            if fresh.targetPct < fresh.maxLossPct {
                fresh.targetPct = fresh.maxLossPct * 1.5
            }
            sessions.removeValue(forKey: profile.id)
            save(fresh)
            log("[session] opened: \(money(stake)) for \(f(minutes, 0))m, limit \(money(fresh.lossLimit)), target \(money(fresh.targetAmount))")
            return .encoded(await sessionPanel(profile, board: b))
        }

        if p == "/api/session/take", req.method == "POST" {
            let profile = activeProfile
            guard var live = session(for: profile.id), live.status == .running else {
                return .error("No session is running.", status: 400)
            }
            let sym = req.json["symbol"] as? String ?? ""
            guard Universe.bySymbol[sym] != nil else { return .error("Unknown symbol.", status: 400) }

            let b = await getBoard()
            let panel = await sessionPanel(profile, board: b)
            guard let candidate = panel.candidates.first(where: { $0.symbol == sym }) else {
                return .error("\(sym) is not on this session's board right now.", status: 400)
            }
            if let blocked = candidate.blocked { return .error(blocked, status: 400) }

            guard let quote = b.quotes[sym], quote.price > 0 else {
                return .error("No live price for \(sym).", status: 503)
            }
            let mark = MarkPrice(quote, dayOpen: b.opens[sym], atr: b.metrics[sym]?.atr14,
                                 fxPerUSD: b.fx.rate(Universe.currency(of: sym)))
            let plan = candidate.plan
            let thesis = "Session trade — a \(candidate.regime) read on five-minute bars, "
                + "\(f(plan.rr, 2)):1 with the stop at \(quoted(plan.stop, candidate.symbol)) and the target at "
                + "\(quoted(plan.target, candidate.symbol)). About \(f(candidate.barsToTarget, 0)) bars, "
                + "\(f(candidate.barsToTarget * 5, 0)) minutes."

            let result = ledger(for: profile).buy(
                symbol: sym, shares: plan.shares, mark: mark,
                target: plan.target, stop: plan.stop, thesis: thesis,
                plannedRisk: plan.riskTaken
            )
            switch result {
            case .failed(let message):
                return .error(message, status: 400)
            case .ok(let trade):
                live.entries.append(SessionEntry(
                    symbol: sym, at: trade.at, entry: trade.price,
                    stop: plan.stop, target: plan.target, shares: trade.shares,
                    plannedRisk: plan.riskTaken, thesis: thesis,
                    closedAt: nil, exit: nil, pnl: nil, rMultiple: nil, trigger: nil
                ))
                save(live)
                return .encoded(await sessionPanel(profile, board: b))
            }
        }

        if p == "/api/session/end", req.method == "POST" {
            let profile = activeProfile
            guard var live = session(for: profile.id), live.status == .running else {
                return .error("No session is running.", status: 400)
            }
            live.status = .stopped
            live.endedAt = nowMs()
            live.endNote = "Ended early, with \(f(live.secondsLeft / 60, 0)) minutes left on the clock."
            save(live)
            let b = await getBoard()
            // Flattening is the session's own rule and applies however it ends.
            _ = refreshSession(profile, board: b)
            if live.flatAtEnd {
                let led = ledger(for: profile)
                let priced = marks(b)
                for entry in live.entries where entry.closedAt == nil {
                    guard let mark = priced[entry.symbol] else { continue }
                    _ = led.sell(symbol: entry.symbol, shares: nil, mark: mark,
                                 reason: "Session ended early; closed at market.", trigger: "session")
                }
                _ = refreshSession(profile, board: b)
            }
            return .encoded(await sessionPanel(profile, board: b))
        }

        if p == "/api/session/clear", req.method == "POST" {
            let profile = activeProfile
            guard let live = session(for: profile.id), live.status.isOver else {
                return .error("A running session cannot be cleared. End it first.", status: 400)
            }
            sessions.removeValue(forKey: profile.id)
            try? FileManager.default.removeItem(at: sessionsDirectory.appendingPathComponent("\(profile.id).json"))
            let b = await getBoard()
            return .encoded(await sessionPanel(profile, board: b))
        }

        /* --- the prediction desk ---------------------------------------------- */

        /* Polymarket's five-minute Bitcoin market, watched and bet on automatically.
         * Deliberately its own bankroll and its own file rather than the trading
         * ledger: a binary contract has no cost basis, no holding period and nothing
         * to sell it back to before it resolves, and putting one through the same
         * FIFO tax lots as a share would produce a ledger wrong about both. */
        if p == "/api/predict" {
            let profile = activeProfile
            let panel = await PredictDesk.shared.panel(profileId: profile.id)
            if panel.run == nil { return .encoded(await PredictDesk.shared.preview()) }
            return .encoded(panel)
        }

        if p == "/api/predict/start", req.method == "POST" {
            let profile = activeProfile
            let bankroll = num(req.json["bankroll"]) ?? 0
            let minutes = num(req.json["minutes"]) ?? 60
            guard bankroll > 0 else { return .error("A run needs a bankroll to bet with.", status: 400) }
            guard minutes >= 10, minutes <= 480 else {
                return .error("A prediction run lasts between ten minutes and eight hours. Under ten it would see one window.", status: 400)
            }
            do {
                let run = try await PredictDesk.shared.open(
                    profileId: profile.id, bankroll: bankroll, minutes: minutes,
                    maxLossPct: Analysis.clamp(num(req.json["maxLossPct"]) ?? 20, 2, 60),
                    targetPct: Analysis.clamp(num(req.json["targetPct"]) ?? 30, 2, 200),
                    maxStakePct: Analysis.clamp(num(req.json["maxStakePct"]) ?? 5, 0.5, 25),
                    kellyFraction: Analysis.clamp(num(req.json["kellyFraction"]) ?? 0.25, 0.05, 1),
                    minEdge: Analysis.clamp(num(req.json["minEdge"]) ?? 0.05, 0.01, 0.3),
                    entryOffsetSeconds: Analysis.clamp(num(req.json["entryOffsetSeconds"]) ?? 0, 0, 250),
                    cutoffSeconds: Analysis.clamp(num(req.json["cutoffSeconds"]) ?? 35, 10, 120),
                    autoBet: (req.json["autoBet"] as? Bool) ?? true,
                    recovery: (req.json["recovery"] as? Bool) ?? false)
                _ = run
            } catch {
                return .error(error.localizedDescription, status: 400)
            }
            return .encoded(await PredictDesk.shared.panel(profileId: profile.id))
        }

        if p == "/api/predict/end", req.method == "POST" {
            let profile = activeProfile
            do { _ = try await PredictDesk.shared.end(profileId: profile.id) }
            catch { return .error(error.localizedDescription, status: 400) }
            return .encoded(await PredictDesk.shared.panel(profileId: profile.id))
        }

        if p == "/api/predict/bet", req.method == "POST" {
            let profile = activeProfile
            guard let raw = req.json["side"] as? String,
                  let side = PredictSide(rawValue: raw) else {
                return .error("A bet needs a side — Up or Down.", status: 400)
            }
            do {
                _ = try await PredictDesk.shared.bet(
                    profileId: profile.id, side: side, stake: num(req.json["stake"]) ?? 0)
            } catch {
                return .error(error.localizedDescription, status: 400)
            }
            return .encoded(await PredictDesk.shared.panel(profileId: profile.id))
        }

        if p == "/api/predict/journal" {
            return .encoded(await PredictDesk.shared.journal(profileId: activeProfile.id))
        }

        /**
         * Is the prediction desk learning, and what has it learned?
         *
         * Its own screen rather than a line on the Predict tab, because the answer
         * is five checks that only mean something together: a desk can have a
         * healthy inflow of evidence, four correctly fitted parameters, and still
         * be unable to place a bet — and no single number says so.
         */
        if p == "/api/predict/audit" {
            return .encoded(await PredictDesk.shared.audit(profileId: activeProfile.id))
        }

        /// Re-runs the candidate contest now rather than on its hourly clock.
        if p == "/api/predict/contest", req.method == "POST" {
            return .encoded(await PredictDesk.shared.runContestNow())
        }

        if p == "/api/predict/clear", req.method == "POST" {
            let profile = activeProfile
            do { try await PredictDesk.shared.clear(profileId: profile.id) }
            catch { return .error(error.localizedDescription, status: 400) }
            return .encoded(await PredictDesk.shared.preview())
        }

        /* --- what the desk has learned ---------------------------------------- */

        if p == "/api/memory" {
            let profile = activeProfile
            let b = await getBoard()
            // Grading is arithmetic over bars that are already in memory, so it runs on
            // every read rather than only when a review is run. A pick made three weeks
            // ago has an answer today whether or not anyone has asked the analyst
            // anything since, and waiting to show it would make the tab look broken.
            regrade(profile, board: b)
            let m = memory(for: profile.id)
            return .encoded(MemoryResponse(
                profileId: profile.id,
                lessons: m.lessons.sorted { rank($0) < rank($1) },
                calibration: m.calibration,
                calibrationLines: m.calibration.lines,
                analysesRun: m.analysesRun,
                updatedAt: m.updatedAt,
                runs: m.runs,
                scoreboard: scoreboard(profile),
                notYetSupported: notYetSupported[profile.id]
            ))
        }

        // Applying and reverting are the same call, because they are the same act:
        // the calibration is recomposed from the whole lesson set either way, so
        // nothing can be left behind by a revert.
        if p == "/api/memory/lesson", req.method == "POST" {
            let id = req.json["id"] as? String ?? ""
            guard let statusRaw = req.json["status"] as? String,
                  let status = LessonStatus(rawValue: statusRaw) else {
                return .error("status must be one of: watching, proposed, applied, dismissed, retired.", status: 400)
            }
            var m = memory(for: activeProfile.id)
            guard let idx = m.lessons.firstIndex(where: { $0.id == id }) else {
                return .error("No lesson with that id on this account.", status: 404)
            }
            // A finding still gathering evidence has no adjustment because it has not
            // earned one; a rule has none by design. Only the first is refused.
            if status == .applied && m.lessons[idx].status == .watching {
                return .error("That finding is still gathering evidence and has not cleared its sample size. It becomes applicable once the record supports it.", status: 400)
            }
            m.lessons[idx].status = status
            m.lessons[idx].updatedAt = nowMs()
            if status == .applied {
                m.lessons[idx].appliedAt = nowMs()
                m.lessons[idx].runsSinceApplied = 0
            } else {
                m.lessons[idx].appliedAt = nil
            }
            save(m)
            // The board's plans were built under the old calibration.
            board = nil
            return .encoded(memory(for: activeProfile.id).calibration)
        }

        if p == "/api/memory/reset", req.method == "POST" {
            var m = Memory.empty(activeProfile.id)
            // The run history is evidence, not opinion, so a "forget what you learned"
            // keeps it unless the caller explicitly says otherwise.
            if req.json["keepHistory"] as? Bool ?? true {
                m.runs = memory(for: activeProfile.id).runs
                m.analysesRun = memory(for: activeProfile.id).analysesRun
            }
            save(m)
            board = nil
            return .json(["ok": true])
        }

        /* --- getting started ---------------------------------------------------- */

        if p == "/api/fx" {
            if fx.at == 0 { fx = await Market.shared.fxRates() }
            return .encoded(fx)
        }

        // Pure: assesses without creating anything, so the wizard can show the
        // consequences of an answer while it is still being chosen.
        if p == "/api/onboarding/assess", req.method == "POST" {
            guard let answers = decode(Onboarding.Answers.self, req.json) else {
                return .error("Those answers could not be read.", status: 400)
            }
            if fx.at == 0 { fx = await Market.shared.fxRates() }
            return .encoded(Onboarding.assess(answers, fx: fx))
        }

        if p == "/api/onboarding/apply", req.method == "POST" {
            guard let body = req.json["profile"], let profile = decode(Profile.self, body) else {
                return .error("That profile could not be read.", status: 400)
            }
            var fresh = profile
            fresh.id = UUID().uuidString
            fresh.createdAt = nowMs()
            let taken = Set(profiles.map(\.name))
            if taken.contains(fresh.name) {
                var n = 2
                while taken.contains("\(fresh.name) \(n)") { n += 1 }
                fresh.name = "\(fresh.name) \(n)"
            }
            profiles.append(fresh)
            activeId = fresh.id
            _ = ledger(for: fresh)
            _ = memory(for: fresh.id)
            persistProfiles()
            settings.hasOnboarded = true
            persistSettings()
            return .encoded(fresh)
        }

        if p == "/api/reset/preview" {
            return .encoded(resetPreview())
        }

        /**
         * Guarded by a typed word rather than a second button. The dialog asks for it
         * because this is the one action in the app that cannot be undone and does not
         * announce itself afterwards — every other destructive thing here is scoped to
         * one account and leaves the rest of the record to argue with.
         */
        if p == "/api/reset/everything", req.method == "POST" {
            // Refused rather than raced. `Task.cancel()` is cooperative, and an analyst
            // run that is mid-flight would finish and write its cache back *after* the
            // reset had removed it — leaving a file belonging to an account that no
            // longer exists, which is exactly the stale state a reset is for escaping.
            if job.status == "running" {
                return .error("An analysis is still running. Stop it first; a run that finishes after the reset would write its results onto an account that no longer exists.", status: 409)
            }
            let typed = (req.json["confirm"] as? String ?? "").trimmingCharacters(in: .whitespaces).lowercased()
            guard typed == "reset" else {
                return .error("Type the word \"reset\" to confirm. This cannot be undone and there is no copy anywhere.", status: 400)
            }
            let removeKey = req.json["removeKey"] as? Bool ?? false
            factoryReset(removeKey: removeKey)
            return .json([
                "ok": true,
                "note": removeKey
                    ? "Everything is gone, including the saved API key. The app is back to a first launch."
                    : "Everything is gone. The saved API key was kept. The app is back to a first launch.",
            ])
        }

        if p == "/api/settings", req.method == "POST" {
            if let done = req.json["hasOnboarded"] as? Bool { settings.hasOnboarded = done }
            persistSettings()
            return .encoded(SettingsResponse(hasOnboarded: settings.hasOnboarded))
        }

        /* --- profiles ---------------------------------------------------------- */

        if p == "/api/profiles" {
            return .encoded(profiles)
        }

        if p == "/api/profile/activate", req.method == "POST" {
            let id = req.json["id"] as? String ?? ""
            guard profiles.contains(where: { $0.id == id }) else {
                return .error("No profile with that id.", status: 404)
            }
            activeId = id
            persistProfiles()
            return .json(["ok": true])
        }

        if p == "/api/profile/save", req.method == "POST" {
            guard let data = try? JSONSerialization.data(withJSONObject: req.json),
                  var incoming = try? JSONDecoder().decode(Profile.self, from: data) else {
                return .error("That profile could not be read.", status: 400)
            }
            // The id becomes part of a file name under the data folder, so only the
            // shape the app itself generates (a UUID) is accepted from the page.
            guard Profile.isValidID(incoming.id) else {
                return .error("That profile id is not valid.", status: 400)
            }
            if let idx = profiles.firstIndex(where: { $0.id == incoming.id }) {
                incoming.createdAt = profiles[idx].createdAt
                profiles[idx] = incoming
                ledger(for: incoming).adoptProfile(incoming)
            } else {
                incoming.createdAt = nowMs()
                profiles.append(incoming)
                activeId = incoming.id
                _ = ledger(for: incoming)
            }
            persistProfiles()
            return .encoded(incoming)
        }

        if p == "/api/profile/new", req.method == "POST" {
            let kindRaw = req.json["preset"] as? String ?? "learner"
            let kind = Profile.PresetKind(rawValue: kindRaw) ?? .learner
            var fresh = Profile.preset(kind)
            fresh.id = UUID().uuidString
            // Two copies of "Day trader" in a switcher help nobody.
            let taken = Set(profiles.map(\.name))
            if taken.contains(fresh.name) {
                var n = 2
                while taken.contains("\(fresh.name) \(n)") { n += 1 }
                fresh.name = "\(fresh.name) \(n)"
            }
            profiles.append(fresh)
            activeId = fresh.id
            _ = ledger(for: fresh)
            persistProfiles()
            return .encoded(fresh)
        }

        if p == "/api/profile/delete", req.method == "POST" {
            let id = req.json["id"] as? String ?? ""
            guard profiles.count > 1 else {
                return .error("This is the only profile. Reset it instead of deleting it.", status: 400)
            }
            guard let idx = profiles.firstIndex(where: { $0.id == id }) else {
                return .error("No profile with that id.", status: 404)
            }
            profiles.remove(at: idx)
            ledgers.removeValue(forKey: id)
            memories.removeValue(forKey: id)
            sessions.removeValue(forKey: id)
            try? FileManager.default.removeItem(at: ledgersDirectory.appendingPathComponent("\(id).json"))
            try? FileManager.default.removeItem(at: memoryDirectory.appendingPathComponent("\(id).json"))
            try? FileManager.default.removeItem(at: sessionsDirectory.appendingPathComponent("\(id).json"))
            if activeId == id { activeId = profiles[0].id }
            persistProfiles()
            return .json(["ok": true])
        }

        /* --- write side ------------------------------------------------------- */

        if p == "/api/trade", req.method == "POST" {
            let body = req.json
            let sym = body["symbol"] as? String ?? ""
            guard Universe.bySymbol[sym] != nil else { return .error("Unknown symbol.", status: 400) }
            let b = await getBoard()
            guard let quote = b.quotes[sym], quote.price > 0 else {
                return .error("No live price for that symbol.", status: 503)
            }
            let mark = MarkPrice(quote, dayOpen: b.opens[sym], atr: b.metrics[sym]?.atr14,
                                 fxPerUSD: b.fx.rate(Universe.currency(of: sym)))
            let led = ledger

            let action = body["action"] as? String
            if action == "buy" {
                let profile = activeProfile
                if !profile.allows(sym) {
                    return .error("\(sym) is outside this profile's universe (\(profile.appetite.label)). Change the universe on the Profile tab if that is intended.", status: 400)
                }
                let openCount = led.state.positions.count
                let holdsIt = led.state.positions.contains { $0.symbol == sym }
                if !holdsIt, openCount >= profile.maxOpenPositions {
                    return .error("This profile allows \(profile.maxOpenPositions) open positions and \(openCount) are already open. Close one first, or raise the limit on the Profile tab.", status: 400)
                }
                // Accept either a share count or a dollar amount; dollars is how people
                // actually think, and shares is what the ledger needs.
                let shares = num(body["shares"]) ?? ((num(body["amount"]) ?? 0) / mark.price)
                let stop = num(body["stop"])
                let result = led.buy(
                    symbol: sym, shares: shares, mark: mark,
                    target: num(body["target"]), stop: stop,
                    thesis: body["thesis"] as? String ?? "Manual entry",
                    plannedRisk: stop.map { (mark.price - $0) * shares }
                )
                switch result {
                case .ok(let trade): return .encoded(TradeAck(ok: true, trade: trade))
                case .failed(let message): return .error(message, status: 400)
                }
            }

            if action == "sell" {
                let result = led.sell(
                    symbol: sym, shares: num(body["shares"]), mark: mark,
                    reason: body["reason"] as? String ?? "Closed manually", trigger: "manual"
                )
                switch result {
                case .ok(let trade): return .encoded(TradeAck(ok: true, trade: trade))
                case .failed(let message): return .error(message, status: 400)
                }
            }

            return .error("action must be \"buy\" or \"sell\".", status: 400)
        }

        if p == "/api/bracket", req.method == "POST" {
            let body = req.json
            let ok = ledger.setBracket(symbol: body["symbol"] as? String ?? "",
                                       target: num(body["target"]), stop: num(body["stop"]))
            return ok ? .json(["ok": true]) : .error("No open position in that symbol.", status: 400)
        }

        if p == "/api/reset", req.method == "POST" {
            resetAccount()
            return .json(["ok": true])
        }

        return .error("Not found", status: 404)
    }

    private func stateResponse(_ b: Board) -> StateResponse {
        let profile = activeProfile
        let led = ledger(for: profile)
        let priced = marks(b)
        let v = led.value(priced)
        let state = led.state

        let summaries = profiles.map { p -> ProfileSummary in
            let l = ledger(for: p)
            let val = l.value(priced)
            return ProfileSummary(
                id: p.id, name: p.name, note: p.note,
                goal: p.goal.label, horizon: p.horizon.label,
                equity: val.equity,
                totalPnlPct: val.totalPnlPct,
                openPositions: val.positions.count,
                active: p.id == profile.id,
                currency: p.currency
            )
        }

        return StateResponse(
            portfolio: v,
            startingCash: state.startingCapital,
            equityCurve: state.equityCurve,
            trades: Array(state.trades.prefix(60)),
            scorecard: led.scorecard(),
            regimes: b.regimes,
            cryptoGlobal: b.cryptoGlobal,
            analyst: Analyst.status(),
            asOf: b.at, pricesAt: b.pricesAt, barsAt: b.barsAt,
            profile: profile,
            profiles: summaries,
            suitability: SuitabilityView(
                capacity: profile.riskCapacity,
                statedRiskPct: profile.riskPctPerTrade,
                suitableRiskPct: profile.suitableRiskPct,
                effectiveRiskPct: profile.effectiveRiskPct,
                capped: profile.isRiskCapped,
                maxHeatPct: profile.maxPortfolioHeatPct,
                note: profile.suitabilityNote
            ),
            session: SessionView(
                equityMarketOpen: [Venue.us, .stockholm].contains { MarketCalendar.isSessionOpen(venue: $0) },
                note: MarketCalendar.boardNote(),
                dayTradesLeft: PDT.remaining(equity: v.equity, records: state.dayTrades,
                                             frictions: profile.frictions),
                clocks: profile.activeVenues.filter(\.hasSession).map(MarketClock.init)
            ),
            tax: led.taxSummary(),
            contributions: Array(state.contributions.prefix(6)),
            currency: profile.currency,
            fx: fx,
            foreignExposureUSD: profile.currency == .usd ? 0 : v.invested,
            learning: learningSummary(profile),
            hasOnboarded: settings.hasOnboarded,
            liveSession: session(for: profile.id).map { live in
                LiveSessionBadge(
                    status: live.status.rawValue, secondsLeft: live.secondsLeft,
                    total: live.realised, lossLimit: live.lossLimit,
                    targetAmount: live.targetAmount,
                    tradesTaken: live.tradesTaken, maxTrades: live.maxTrades
                )
            },
            ledgerError: led.loadError,
            readingModes: ReadingMode.allCases.map(ReadingModeView.init)
        )
    }

    /* ------------------------------------------------------------ factory reset */

    /// Counts what a full reset would take, so the confirmation can name it.
    func resetPreview() -> ResetPreview {
        var trades = 0, closed = 0, open = 0
        for profile in profiles {
            let state = ledger(for: profile).state
            trades += state.trades.count
            closed += state.trades.filter { $0.action == "sell" }.count
            open += state.positions.count
        }
        let allMemories = profiles.map { memory(for: $0.id) }
        let lessons = allMemories.reduce(0) { $0 + $1.lessons.count }
        let applied = allMemories.reduce(0) { $0 + $1.applied.count }
        let runs = allMemories.reduce(0) { $0 + $1.analysesRun }
        let liveSessions = profiles.compactMap { session(for: $0.id) }.count
        let oldest = profiles.map(\.createdAt).min() ?? nowMs()
        let days = Int((nowMs() - oldest) / 86_400_000)
        let credentials = Credentials.resolve()

        var items: [String] = []
        items.append("\(profiles.count) account\(profiles.count == 1 ? "" : "s"), with every setting on \(profiles.count == 1 ? "it" : "them")")
        if trades > 0 {
            items.append("\(trades) journal entr\(trades == 1 ? "y" : "ies") — \(closed) closed trade\(closed == 1 ? "" : "s") and the reasoning recorded at the time")
        }
        if open > 0 { items.append("\(open) open position\(open == 1 ? "" : "s")") }
        if lessons > 0 {
            items.append("\(lessons) finding\(lessons == 1 ? "" : "s") measured from your record\(applied > 0 ? ", \(applied) of them currently applied to every level it produces" : "")")
        }
        if runs > 0 { items.append("\(runs) recorded analys\(runs == 1 ? "is" : "es") and how each one turned out") }
        if liveSessions > 0 { items.append("\(liveSessions) day-trading session\(liveSessions == 1 ? "" : "s")") }
        items.append("the token accounting for the last analyst run")

        return ResetPreview(
            profiles: profiles.count, trades: trades, openPositions: open,
            closedTrades: closed, lessons: lessons, appliedLessons: applied,
            analysisRuns: runs, sessions: liveSessions, oldestAccountDays: days,
            hasKeychainKey: Credentials.readKeychain() != nil,
            keySource: credentials?.source.rawValue ?? "none",
            dataDirectory: Desk.dataDirectory.path,
            items: items
        )
    }

    /**
     * Everything, back to a first launch.
     *
     * Every file this app has ever written is removed and the five presets are laid
     * down again, so the next launch is indistinguishable from the first one. That is
     * the point — a reset that leaves a stale cache or a half-applied calibration
     * behind is worse than none, because the thing you were trying to escape is still
     * there and now it is invisible.
     *
     * The API key is the one exception and it is opt-in. A credential is not this
     * app's to throw away on the way past, and someone resetting an account they made
     * a mess of is not usually asking to go and find their key again.
     */
    func factoryReset(removeKey: Bool) {
        analysisTask?.cancel()
        analysisTask = nil
        governor = nil
        job = AnalysisJob()

        let fm = FileManager.default
        for directory in [ledgersDirectory, memoryDirectory, sessionsDirectory] {
            try? fm.removeItem(at: directory)
        }
        for file in [profilesURL, analysisURL, reviewURL, telemetryURL, settingsURL,
                     // The pre-profiles single ledger, which openLedgers would otherwise
                     // migrate straight back in as the learner's history.
                     Desk.dataDirectory.appendingPathComponent("portfolio.json")] {
            try? fm.removeItem(at: file)
        }

        profiles = []
        ledgers = [:]
        memories = [:]
        sessions = [:]
        notYetSupported = [:]
        lastRun = nil
        board = nil
        barsCache = nil
        settings = AppSettings()
        AnalystModel.adopt(main: nil, fast: nil)

        if removeKey { _ = Credentials.deleteKeychain() }

        // Lays the presets down again exactly as a first launch does. Nothing is
        // migrated in, because there is no longer anything to migrate from.
        openLedgers()
        let keyNote = removeKey ? "including the saved API key" : "the saved API key was kept"
        log("[reset] everything erased — \(keyNote)")
    }

    /// Wipes the active profile's positions and history back to its opening
    /// balance. Also reachable from the app's own File menu.
    func resetAccount() {
        ledger.reset()
    }

    private func encodeJob() -> [String: Any] {
        var out: [String: Any] = [
            "status": job.status,
            "kind": job.kind,
            "startedAt": job.startedAt,
            "finishedAt": job.finishedAt,
            "candidates": job.candidates,
        ]
        if let stage = job.stage { out["stage"] = stage.rawValue }
        if let error = job.error { out["error"] = error }
        return out
    }

    /// A JSON fragment straight from the request body into a Codable. Used by the
    /// routes that take a whole struct rather than a handful of fields.
    private func decode<T: Decodable>(_ type: T.Type, _ any: Any) -> T? {
        guard JSONSerialization.isValidJSONObject(any),
              let data = try? JSONSerialization.data(withJSONObject: any) else { return nil }
        return try? JSONDecoder().decode(T.self, from: data)
    }

    /// The order the Learning tab reads in: things waiting on you, then what is
    /// live, then what is still being watched, then what has been settled.
    private func rank(_ lesson: Lesson) -> Int {
        switch lesson.status {
        case .proposed: return 0
        case .applied: return 1
        case .watching: return 2
        case .retired: return 3
        case .dismissed: return 4
        }
    }

    private func num(_ any: Any?) -> Double? {
        if let d = any as? Double { return d.isFinite ? d : nil }
        if let i = any as? Int { return Double(i) }
        if let s = any as? String, let d = Double(s) { return d }
        return nil
    }
}

struct TradeAck: Codable {
    let ok: Bool
    let trade: Trade
}
