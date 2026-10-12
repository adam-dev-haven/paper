/**
 * Credentials.swift — where the analyst's key lives.
 *
 * Paper can run without any key: the ranking, the levels, the position sizes and the
 * refusals all come from the local risk engine. A key adds the written analysis, and
 * the app holds one in the **Keychain**, which is the only place on this platform that
 * is not a lie about security. Not in `Application Support` next to the ledgers, where a
 * JSON file with a live API key in it would sit world-readable in a backup forever.
 *
 * The rules this file exists to enforce:
 *
 *   - The key is written to the Keychain and read back only to make a request. It
 *     is never written to a log, never returned by an API route, never included in
 *     an export, and never held in the analysis cache.
 *   - Nothing outside this file ever sees the whole string. Everything that has to
 *     *refer* to a key gets a `fingerprint` — the prefix and last four characters —
 *     which is enough to answer "is this the key I pasted?" and useless to anyone
 *     who reads it over your shoulder.
 *   - Saving verifies before it stores. A key that is merely persisted tells you
 *     nothing; one that has answered a real request tells you it works. The check
 *     costs a single token.
 *   - The resolution order is stated in the interface, because "why is it still
 *     using the old key" is otherwise unanswerable: the Keychain entry first, then
 *     the `ANTHROPIC_API_KEY` environment variable. No file is ever read for a key.
 */

import Foundation
import Security

enum Credentials {

    /// The Keychain service follows the bundle identifier, so a build with its own identifier keeps its own entry.
    private static let service = Bundle.main.bundleIdentifier ?? "com.example.paper"
    private static let account = "ANTHROPIC_API_KEY"

    /// Where a resolved key came from. Shown in the interface so the precedence is
    /// never a mystery.
    enum Source: String, Codable {
        case keychain, environment, none

        var label: String {
            switch self {
            case .keychain: return "Saved in Paper's Keychain entry"
            case .environment: return "ANTHROPIC_API_KEY in the environment"
            case .none: return "No key found"
            }
        }
    }

    struct Status: Codable {
        let hasKey: Bool
        let source: Source
        let sourceLabel: String
        /// `sk-ant-…7f2a`. Never the key.
        let fingerprint: String?
        /// True when this app owns the entry and can therefore remove it.
        let removable: Bool
        let note: String
    }

    /* -------------------------------------------------------------- keychain */

    static func readKeychain() -> String? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ]
        var item: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &item) == errSecSuccess,
              let data = item as? Data,
              let value = String(data: data, encoding: .utf8),
              !value.isEmpty
        else { return nil }
        return value
    }

    @discardableResult
    static func writeKeychain(_ key: String) -> Bool {
        let base: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
        ]
        // Delete first rather than trying to update: an update on a missing item
        // fails, and branching on which case we are in is a race.
        SecItemDelete(base as CFDictionary)

        var insert = base
        insert[kSecValueData as String] = Data(key.utf8)
        insert[kSecAttrLabel as String] = "Paper — Anthropic API key"
        // The key is only ever needed while someone is using the app, so it does not
        // need to survive a locked screen and should not be readable from a backup
        // restored onto another machine.
        insert[kSecAttrAccessible as String] = kSecAttrAccessibleWhenUnlockedThisDeviceOnly
        return SecItemAdd(insert as CFDictionary, nil) == errSecSuccess
    }

    @discardableResult
    static func deleteKeychain() -> Bool {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
        ]
        let status = SecItemDelete(query as CFDictionary)
        return status == errSecSuccess || status == errSecItemNotFound
    }

    /* ------------------------------------------------------------ resolution */

    /**
     * The key, and where it came from.
     *
     * The Keychain wins. Someone who has just typed a key into this app and pressed
     * save expects that key to be the one in use, and an environment variable set
     * three months ago silently outranking it is the kind of behaviour that costs an
     * hour to diagnose.
     */
    static func resolve() -> (key: String, source: Source)? {
        if let k = readKeychain() { return (k, .keychain) }
        if let k = ProcessInfo.processInfo.environment["ANTHROPIC_API_KEY"], !k.isEmpty {
            return (k, .environment)
        }
        return nil
    }

    /// Enough to recognise a key you have seen before, and useless to anyone else.
    static func fingerprint(_ key: String) -> String {
        let trimmed = key.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.count > 12 else { return "…" + String(trimmed.suffix(2)) }
        return String(trimmed.prefix(7)) + "…" + String(trimmed.suffix(4))
    }

    static func status() -> Status {
        guard let (key, source) = resolve() else {
            return Status(
                hasKey: false, source: .none, sourceLabel: Source.none.label,
                fingerprint: nil, removable: false,
                note: "The analyst is off. Everything else works: the ranking, the levels, the position sizes and the refusals all come from the risk engine, and each pick carries a reading generated from its metrics. A key adds the news reading, the cross-correlation view and the written brief. Paste one below to switch it on; it is stored in your Keychain, never in a file."
            )
        }
        return Status(
            hasKey: true, source: source, sourceLabel: source.label,
            fingerprint: fingerprint(key),
            removable: source == .keychain,
            note: source == .keychain
                ? "The analyst is on, using the key saved here. It lives in your login Keychain rather than in the data folder, so it is not in a backup of the ledgers."
                : "The analyst is on, using the ANTHROPIC_API_KEY environment variable. A key saved here would take precedence over it; removing that one would fall back to this."
        )
    }

    /* ----------------------------------------------------------- validation */

    enum CheckResult {
        case ok(model: String)
        /// The key was rejected. The message is already fit to show a person.
        case rejected(String)
        /// Something else went wrong — network, rate limit, an outage.
        case unavailable(String)
    }

    /**
     * One real request, with `max_tokens: 1` and no thinking, to find out whether a
     * key actually works before it is stored.
     *
     * Persisting an unverified key is the worst of both worlds: the app reports
     * itself configured, every analysis fails, and the error surfaces three screens
     * away from the field that caused it.
     */
    static func check(_ key: String, model: String) async -> CheckResult {
        let trimmed = key.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return .rejected("No key was entered.") }
        guard trimmed.hasPrefix("sk-ant-") else {
            return .rejected("An Anthropic API key starts with \"sk-ant-\" and this does not, so it would be rejected on the first request. Check the whole key was copied, and that it is an API key from console.anthropic.com.")
        }
        guard !trimmed.contains(where: { $0.isWhitespace }) else {
            return .rejected("That key contains a space or a line break, which usually means part of the page was copied along with it. Copy just the key.")
        }

        var req = URLRequest(url: URL(string: "https://api.anthropic.com/v1/messages")!)
        req.httpMethod = "POST"
        req.timeoutInterval = 25
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.setValue(trimmed, forHTTPHeaderField: "x-api-key")
        req.setValue("2023-06-01", forHTTPHeaderField: "anthropic-version")
        req.httpBody = try? JSONSerialization.data(withJSONObject: [
            "model": model,
            "max_tokens": 1,
            "messages": [["role": "user", "content": "."]],
        ])

        do {
            let (data, response) = try await URLSession.shared.data(for: req)
            guard let http = response as? HTTPURLResponse else {
                return .unavailable("No response from the API.")
            }
            // A 1-token cap stops on max_tokens, which is a success: the request was
            // authorised, billed and answered.
            if (200...299).contains(http.statusCode) { return .ok(model: model) }

            let body = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
            let apiMessage = ((body?["error"] as? [String: Any])?["message"] as? String) ?? ""

            switch http.statusCode {
            case 401:
                return .rejected("Anthropic rejected the key (401). It is either mistyped, revoked, or from a different account. Generate a fresh one at console.anthropic.com and paste that.")
            case 403:
                return .rejected("The key authenticated but is not permitted to use \(model) (403). That usually means the account has no credit on it, or the model is not enabled for it. \(apiMessage)")
            case 404:
                return .rejected("The model \(model) was not found for this account (404). Pick a different one under Settings → Analyst; the key itself may be valid.")
            case 429:
                return .unavailable("The key works, but the account is rate limited (429). Wait a minute and try again.")
            case 400:
                return .rejected("The API refused the request (400): \(apiMessage.isEmpty ? "no detail given" : apiMessage)")
            case 500...599:
                return .unavailable("Anthropic returned \(http.statusCode). That is their side, not the key's. Try again shortly.")
            default:
                return .unavailable("Unexpected response \(http.statusCode). \(apiMessage)")
            }
        } catch {
            let ns = error as NSError
            if ns.domain == NSURLErrorDomain {
                return .unavailable("Could not reach api.anthropic.com: \(error.localizedDescription). The key was not tested, so it has not been saved. Check the network and try again.")
            }
            return .unavailable(error.localizedDescription)
        }
    }
}
