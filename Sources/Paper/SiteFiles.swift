/**
 * SiteFiles.swift — serving the interface off disk.
 *
 * In a built app the site lives in `Paper.app/Contents/Resources/site`. Running
 * the binary straight out of `.build` there is no bundle to look in, so it walks
 * up to the project's own `site/` — which means an edit to a stylesheet shows up
 * on the next reload without a rebuild.
 */

import Foundation

enum SiteFiles {
    private static let mime: [String: String] = [
        "html": "text/html; charset=utf-8",
        "css": "text/css; charset=utf-8",
        "js": "text/javascript; charset=utf-8",
        "json": "application/json",
        "svg": "image/svg+xml",
        "woff2": "font/woff2",
        "png": "image/png",
    ]

    /// Resolved once: the bundled copy if there is one, else the source tree.
    static let root: URL = {
        if let bundled = Bundle.main.resourceURL?.appendingPathComponent("site", isDirectory: true),
           FileManager.default.fileExists(atPath: bundled.appendingPathComponent("index.html").path) {
            return bundled
        }
        // .build/<config>/Paper → up three to the project root.
        var dir = URL(fileURLWithPath: CommandLine.arguments[0]).resolvingSymlinksInPath().deletingLastPathComponent()
        for _ in 0..<5 {
            let candidate = dir.appendingPathComponent("site", isDirectory: true)
            if FileManager.default.fileExists(atPath: candidate.appendingPathComponent("index.html").path) {
                return candidate
            }
            dir = dir.deletingLastPathComponent()
        }
        return URL(fileURLWithPath: FileManager.default.currentDirectoryPath).appendingPathComponent("site", isDirectory: true)
    }()

    /// The page that carries the session token. Every other file is served as it is.
    static func isEntryPage(_ pathname: String) -> Bool { pathname == "/" || pathname == "/index.html" }

    /// Puts the token where `api.js` reads it. If the page has no `<head>` there is
    /// nowhere safe to put it, and the page is served without one: the app then
    /// refuses its own API calls, which is the failure that is easy to see.
    static func withToken(_ html: Data, _ token: String) -> Data {
        guard var text = String(data: html, encoding: .utf8), let at = text.range(of: "<head>") else { return html }
        text.insert(contentsOf: "\n<meta name=\"paper-token\" content=\"\(token)\">", at: at.upperBound)
        return Data(text.utf8)
    }

    static func serve(_ pathname: String, sessionToken: String? = nil) -> HTTPResponse {
        var response = serveFile(pathname)
        if let sessionToken, response.status == 200, isEntryPage(pathname) {
            response.body = withToken(response.body, sessionToken)
        }
        return response
    }

    private static func serveFile(_ pathname: String) -> HTTPResponse {
        let rel = pathname == "/" ? "/index.html" : pathname
        // Resolve and confirm the result is still inside site/, so ../ cannot escape.
        let target = root.appendingPathComponent(rel).standardizedFileURL
        let base = root.standardizedFileURL
        guard target.path == base.path || target.path.hasPrefix(base.path + "/") else {
            return .notFound()
        }
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: target.path, isDirectory: &isDirectory),
              !isDirectory.boolValue,
              let data = try? Data(contentsOf: target)
        else { return .notFound() }

        let ext = target.pathExtension.lowercased()
        return HTTPResponse(
            status: 200,
            contentType: mime[ext] ?? "application/octet-stream",
            body: data
        )
    }
}
