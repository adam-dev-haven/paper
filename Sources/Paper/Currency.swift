/**
 * Currency.swift — one unit of account, and a second one to read it in.
 *
 * Every instrument Paper follows is quoted and traded in dollars, because that is
 * what the feeds return and what an order would actually carry. So the ledger is
 * in dollars, the interface is in dollars, and every sentence the app writes about
 * money is in dollars. There is exactly one unit and nothing has to guess which.
 *
 * That single rule is load-bearing. The previous design denominated the *account*
 * in the profile's currency while leaving instrument prices in dollars, and it was
 * correct on every screen that went through the interface's formatter and wrong on
 * every sentence composed in Swift — which spoke through a `money()` that hardcoded
 * a dollar sign. An account set to kronor showed `104 600 kr` of equity in the
 * header and told you, four lines down, that the session limit was `$500`. Two
 * currencies for one quantity is a bug generator, not a feature: every new piece of
 * prose is a fresh chance to pick the wrong one.
 *
 * What survives is the part that was actually useful. `homeCurrency` is what the
 * principal thinks in, and it buys a **second, smaller figure** printed beside the
 * dollar one — the equity, the cash, the day's profit, what a trade puts at risk.
 * A companion, never a replacement. The dollar figure is the number; the kronor
 * figure is the translation, and it is styled so you can tell at a glance which is
 * which.
 *
 * This is also what a Swedish or German broker actually shows you for a US holding,
 * and it is the only version that does not invent prices.
 *
 * What it still deliberately does not do is pretend the ledger settles in kronor.
 * The positions are dollar positions; a real SEK account holding them carries a
 * USD/SEK exposure of the same size, whose swings land in the P/L alongside the
 * stock's. Paper states that exposure on the desk rather than modelling it, because
 * modelling it means re-denominating every historical fill at the rate that applied
 * on the day, and a ledger that quietly rewrites its own past to match today's rate
 * is worse than one that is honest about its scope.
 */

import Foundation

enum Currency: String, Codable, CaseIterable {
    case usd = "USD"
    case eur = "EUR"
    case sek = "SEK"
    case gbp = "GBP"
    case nok = "NOK"
    case dkk = "DKK"
    case chf = "CHF"
    case cad = "CAD"
    case aud = "AUD"
    case jpy = "JPY"

    var code: String { rawValue }

    /// What goes in front of, or after, the number.
    var symbol: String {
        switch self {
        case .usd: return "$"
        case .eur: return "€"
        case .sek: return "kr"
        case .gbp: return "£"
        case .nok: return "kr"
        case .dkk: return "kr"
        case .chf: return "CHF"
        case .cad: return "C$"
        case .aud: return "A$"
        case .jpy: return "¥"
        }
    }

    /// Nordic kronor and francs trail their symbol; the rest lead. Getting this
    /// wrong is a small thing that makes the whole interface read as foreign.
    var symbolTrails: Bool {
        switch self {
        case .sek, .nok, .dkk, .chf: return true
        default: return false
        }
    }

    /// How many decimals a figure in this currency is worth showing. Yen has no
    /// subunit in practice, so two decimal places on it are noise.
    var decimals: Int { self == .jpy ? 0 : 2 }

    /// The locale whose grouping and decimal separators this currency is normally
    /// written with. `1 234,56 kr`, not `1,234.56 kr`.
    var locale: String {
        switch self {
        case .usd: return "en-US"
        case .eur: return "de-DE"
        case .sek: return "sv-SE"
        case .gbp: return "en-GB"
        case .nok: return "nb-NO"
        case .dkk: return "da-DK"
        case .chf: return "de-CH"
        case .cad: return "en-CA"
        case .aud: return "en-AU"
        case .jpy: return "ja-JP"
        }
    }

    var name: String {
        switch self {
        case .usd: return "US dollar"
        case .eur: return "Euro"
        case .sek: return "Swedish krona"
        case .gbp: return "Pound sterling"
        case .nok: return "Norwegian krone"
        case .dkk: return "Danish krone"
        case .chf: return "Swiss franc"
        case .cad: return "Canadian dollar"
        case .aud: return "Australian dollar"
        case .jpy: return "Japanese yen"
        }
    }

    /// The pair Yahoo quotes it against the dollar with, and which way round.
    /// `inverted` means the quote is dollars per unit, so the rate has to be flipped
    /// to get units per dollar.
    var pair: (symbol: String, inverted: Bool)? {
        switch self {
        case .usd: return nil
        case .eur: return ("EURUSD=X", true)    // dollars per euro
        case .gbp: return ("GBPUSD=X", true)
        case .aud: return ("AUDUSD=X", true)
        case .sek: return ("USDSEK=X", false)   // kronor per dollar
        case .nok: return ("USDNOK=X", false)
        case .dkk: return ("USDDKK=X", false)
        case .chf: return ("USDCHF=X", false)
        case .cad: return ("USDCAD=X", false)
        case .jpy: return ("USDJPY=X", false)
        }
    }

    /// A plausible standing rate, used only when the FX feed is unreachable. Shown
    /// as an estimate rather than passed off as live — a converted figure whose
    /// rate is unknown is worse than no conversion at all, so the interface always
    /// says which it is looking at.
    var fallbackPerUSD: Double {
        switch self {
        case .usd: return 1
        case .eur: return 0.92
        case .sek: return 10.5
        case .gbp: return 0.79
        case .nok: return 10.8
        case .dkk: return 6.85
        case .chf: return 0.88
        case .cad: return 1.36
        case .aud: return 1.52
        case .jpy: return 152
        }
    }

    /**
     * What the machine says the person reads money in.
     *
     * This is the whole answer to "the app should understand the system currency
     * right off the bat". macOS already knows — the region set in System Settings
     * carries a currency, and a Mac configured for Sweden reports SEK without ever
     * being asked. Reading it means the first screen is already right for the
     * person in front of it instead of defaulting to dollars and waiting to be
     * corrected, which is the version nobody gets around to.
     *
     * Unsupported currencies fall back to dollars rather than guessing at a near
     * neighbour, and because the ledger is in dollars anyway, that fallback costs
     * nothing but the companion figure.
     */
    static var systemDefault: Currency {
        guard let code = Locale.current.currency?.identifier else { return .usd }
        return Currency(rawValue: code.uppercased()) ?? .usd
    }

    /// True when this currency needs a second figure at all. Dollars are already
    /// the number on screen, so printing them twice is noise.
    var needsCompanion: Bool { self != .usd }
}

/**
 * A price, in the currency the instrument is quoted in.
 *
 * The companion to `money()`, and the distinction between them is the whole of
 * the currency model: `money()` writes an amount the account holds, which is
 * always dollars, and this writes a level on a chart, which is whatever the
 * exchange quotes. A stop at 337 kr written as "$337" is not a rounding error —
 * it is a level a hundredfold away from anything that exists.
 *
 * Decimals follow the magnitude, as `priceText` does, so a 0.089 stop does not
 * become "0.09".
 */
func quoted(_ n: Double, _ symbol: String) -> String {
    let currency = Universe.currency(of: symbol)
    let text = priceText(n)
    return currency.symbolTrails ? "\(text) \(currency.symbol)" : "\(currency.symbol)\(text)"
}

/// Units of each currency one dollar buys, plus when that was true.
struct FXRates: Codable {
    /// Keyed by currency code. `perUSD["SEK"] = 10.46` means one dollar is 10.46 kronor.
    var perUSD: [String: Double]
    var at: Double
    /// False when the feed failed and the standing estimates are in use.
    var live: Bool

    static let unavailable = FXRates(
        perUSD: Dictionary(uniqueKeysWithValues: Currency.allCases.map { ($0.code, $0.fallbackPerUSD) }),
        at: 0, live: false
    )

    func rate(_ currency: Currency) -> Double {
        let r = perUSD[currency.code] ?? currency.fallbackPerUSD
        return r.isFinite && r > 0 ? r : currency.fallbackPerUSD
    }

    /// The ledger's dollars, expressed in what the principal reads in. Used only
    /// for the companion figure — nothing downstream of this is ever stored.
    func fromUSD(_ amount: Double, _ currency: Currency) -> Double { amount * rate(currency) }

    /// The other way. Kept for the one place it is still needed: a person who
    /// knows their savings in kronor and wants to see what that is to type in.
    func toUSD(_ amount: Double, _ currency: Currency) -> Double { amount / rate(currency) }

    /// Said in one line wherever a companion figure appears, so the second number
    /// is never shown without the rate that produced it.
    func note(_ currency: Currency) -> String {
        guard currency.needsCompanion else {
            return "Every figure here is in US dollars: the ledger, the prices, the profit and everything written about them. That is the currency these instruments are quoted and traded in."
        }
        let r = rate(currency)
        let when = live ? "the live rate" : "a standing estimate, because the rate feed is unreachable"
        return "The account trades and settles in dollars. The smaller \(currency.code) figure beside each amount is a conversion at \(f(r, 4)) \(currency.code) per USD, \(when). It is for reading only and is not a price you could deal at."
    }
}

extension Market {
    /**
     * Every pair that covers a currency someone might read in, in one batched request.
     *
     * Reuses `livePrices` rather than adding a second fetch path: a currency pair on
     * Yahoo is a symbol like any other, and the cache-busting and chunking that make
     * the price feed honest apply to it unchanged.
     */
    func fxRates(ttlMs: Double = 600_000) async -> FXRates {
        let symbols = Currency.allCases.compactMap { $0.pair?.symbol }
        guard !symbols.isEmpty else { return .unavailable }

        let quotes = (try? await livePrices(symbols, ttlMs: ttlMs)) ?? [:]
        var perUSD: [String: Double] = ["USD": 1]
        var live = true

        for currency in Currency.allCases where currency != .usd {
            guard let pair = currency.pair,
                  let quote = quotes[pair.symbol], quote.price > 0, quote.price.isFinite else {
                perUSD[currency.code] = currency.fallbackPerUSD
                live = false
                continue
            }
            perUSD[currency.code] = pair.inverted ? 1 / quote.price : quote.price
        }

        if !live { log("[fx] one or more rates unavailable; standing estimates in use for those.", .warn, "fx") }
        return FXRates(perUSD: perUSD, at: nowMs(), live: live)
    }
}
