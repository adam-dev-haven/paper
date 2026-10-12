/**
 * HTTPServer.swift — a loopback HTTP/1.1 server, just big enough for one desk.
 *
 * Paper's interface is the web app in `site/`, and it talks to the engine over
 * `fetch`. Rather than rewrite that in SwiftUI, the app *is* the server: this
 * binds an ephemeral port on 127.0.0.1, the window loads it in a WKWebView, and
 * the front end never learns it moved.
 *
 * A custom WKURLSchemeHandler would have avoided the socket entirely, but WebKit
 * drops the body of a POST made through one, and half of Paper's API is POSTs
 * carrying JSON. A real socket keeps the request intact.
 *
 * The port is ephemeral and the bind address is loopback, so nothing outside this
 * machine can reach it, and no two copies of the app can collide on a port.
 *
 * Loopback is not the same as private, though. Any web page open in a browser on this
 * machine can send requests to 127.0.0.1, and a page that rebinds its own domain name
 * to 127.0.0.1 can read the answers. `RequestGate` is what stops both: a request is
 * refused unless it names this server in `Host`, comes from this server's own origin,
 * and carries the per-launch token that only the page served from here ever receives.
 */

import Foundation
import Network

struct HTTPRequest {
    let method: String
    /// Path plus query string, exactly as the browser sent it.
    let target: String
    let body: Data
    /// Header names are lower-cased. Empty for requests built in tests.
    var headers: [String: String] = [:]

    var path: String {
        target.split(separator: "?", maxSplits: 1).first.map(String.init) ?? target
    }

    /// One query parameter, percent-decoded.
    func query(_ name: String) -> String? {
        guard let q = target.split(separator: "?", maxSplits: 1).dropFirst().first else { return nil }
        for pair in q.split(separator: "&") {
            let parts = pair.split(separator: "=", maxSplits: 1)
            guard String(parts[0]) == name else { continue }
            let raw = parts.count > 1 ? String(parts[1]) : ""
            return raw.replacingOccurrences(of: "+", with: " ").removingPercentEncoding ?? raw
        }
        return nil
    }

    var json: [String: Any] {
        (try? JSONSerialization.jsonObject(with: body)) as? [String: Any] ?? [:]
    }
}

struct HTTPResponse {
    var status: Int = 200
    var contentType: String = "application/json"
    var body: Data = Data()

    static func json(_ object: Any, status: Int = 200) -> HTTPResponse {
        let data = (try? JSONSerialization.data(withJSONObject: object)) ?? Data("{}".utf8)
        return HTTPResponse(status: status, contentType: "application/json", body: data)
    }

    static func encoded<T: Encodable>(_ value: T, status: Int = 200) -> HTTPResponse {
        let encoder = JSONEncoder()
        do {
            return HTTPResponse(status: status, contentType: "application/json", body: try encoder.encode(value))
        } catch {
            return .error("Could not encode the response: \(error.localizedDescription)", status: 500)
        }
    }

    static func error(_ message: String, status: Int) -> HTTPResponse {
        .json(["error": message], status: status)
    }

    static func notFound() -> HTTPResponse {
        HTTPResponse(status: 404, contentType: "text/plain; charset=utf-8", body: Data("Not found".utf8))
    }
}

/**
 * Decides whether a request may reach the handler at all.
 *
 * The token is 256 random bits made once per launch and handed out only inside the
 * served `index.html`, so a page on another origin cannot learn it: it can send a
 * request, but it cannot read the page that carries the token. `Host` is checked
 * against the exact address and port, which is what defeats DNS rebinding, where a
 * hostile page makes its own domain name resolve to 127.0.0.1 so the browser treats
 * this server as that page's own origin.
 */
final class RequestGate: @unchecked Sendable {
    enum Verdict: Equatable {
        case allow
        case refuse(status: Int, message: String)
    }

    static let header = "x-paper-token"

    let token: String
    private let lock = NSLock()
    private var boundPort: UInt16 = 0

    init(token: String = RequestGate.makeToken()) { self.token = token }

    /// Set by `HTTPServer.start` once the kernel has chosen a port. Until then every
    /// request is refused, which is the safe direction to be wrong in.
    var port: UInt16 {
        get { lock.lock(); defer { lock.unlock() }; return boundPort }
        set { lock.lock(); boundPort = newValue; lock.unlock() }
    }

    static func makeToken() -> String {
        var bytes = [UInt8](repeating: 0, count: 32)
        let status = SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes)
        precondition(status == errSecSuccess, "the system could not produce random bytes")
        return bytes.map { String(format: "%02x", $0) }.joined()
    }

    func verdict(for request: HTTPRequest) -> Verdict {
        let port = self.port
        let origin = "http://127.0.0.1:\(port)"
        guard port != 0, request.headers["host"] == "127.0.0.1:\(port)" else {
            return .refuse(status: 403, message: "Unexpected Host header.")
        }
        if let sent = request.headers["origin"], sent != origin {
            return .refuse(status: 403, message: "Cross-origin requests are not accepted.")
        }
        if let site = request.headers["sec-fetch-site"], site != "same-origin", site != "none" {
            return .refuse(status: 403, message: "Cross-site requests are not accepted.")
        }
        if request.path.hasPrefix("/api/") {
            guard let sent = request.headers[RequestGate.header], Self.sameToken(sent, token) else {
                return .refuse(status: 403, message: "Missing or wrong session token. Reload the desk.")
            }
        }
        return .allow
    }

    /// Compares without stopping at the first difference.
    private static func sameToken(_ a: String, _ b: String) -> Bool {
        let x = Array(a.utf8), y = Array(b.utf8)
        var diff = x.count ^ y.count
        for i in 0..<min(x.count, y.count) { diff |= Int(x[i] ^ y[i]) }
        return diff == 0
    }
}

final class HTTPServer {
    typealias Handler = (HTTPRequest) async -> HTTPResponse

    /// A header block over this is not a browser. Nothing Paper sends comes near it.
    static let maxHeaderBytes = 32 * 1024
    /// The largest body any route reads is a profile or a trade, a few kilobytes.
    static let maxBodyBytes = 2 * 1024 * 1024
    /// A connection that has not produced a full request by now is abandoned.
    static let connectionSeconds = 30.0

    private let handler: Handler
    private let gate: RequestGate?
    private let queue = DispatchQueue(label: "paper.http", attributes: .concurrent)
    private var listener: NWListener?

    init(gate: RequestGate? = nil, handler: @escaping Handler) {
        self.gate = gate
        self.handler = handler
    }

    /// Binds and blocks until the kernel has handed us a port, then returns it.
    func start() throws -> UInt16 {
        let params = NWParameters.tcp
        params.allowLocalEndpointReuse = true
        params.requiredLocalEndpoint = NWEndpoint.hostPort(host: .ipv4(.loopback), port: .any)
        (params.defaultProtocolStack.internetProtocol as? NWProtocolIP.Options)?.version = .v4

        let l = try NWListener(using: params)
        l.newConnectionHandler = { [weak self] conn in self?.accept(conn) }

        let ready = DispatchSemaphore(value: 0)
        var failure: Error?
        l.stateUpdateHandler = { state in
            switch state {
            case .ready: ready.signal()
            case .failed(let error), .waiting(let error): failure = error; ready.signal()
            default: break
            }
        }
        l.start(queue: queue)
        listener = l

        if ready.wait(timeout: .now() + 10) == .timedOut {
            throw MarketError("the local server did not come up within ten seconds")
        }
        if let failure { throw failure }
        guard let port = l.port?.rawValue, port != 0 else {
            throw MarketError("the local server started without a port")
        }
        gate?.port = port
        return port
    }

    func stop() {
        listener?.cancel()
        listener = nil
    }

    private func accept(_ conn: NWConnection) {
        conn.start(queue: queue)
        // Cancelling a connection that already finished is a no-op.
        queue.asyncAfter(deadline: .now() + HTTPServer.connectionSeconds) { conn.cancel() }
        read(conn, buffer: Data())
    }

    private func read(_ conn: NWConnection, buffer: Data) {
        conn.receive(minimumIncompleteLength: 1, maximumLength: 1 << 16) { [weak self] data, _, isComplete, error in
            guard let self else { conn.cancel(); return }
            var buf = buffer
            if let data { buf.append(data) }
            if error != nil { conn.cancel(); return }

            switch HTTPServer.parse(buf) {
            case .complete(let request):
                if let gate = self.gate, case .refuse(let status, let message) = gate.verdict(for: request) {
                    self.send(conn, .error(message, status: status))
                    return
                }
                Task {
                    let response = await self.handler(request)
                    self.send(conn, response)
                }
            case .partial:
                if isComplete { conn.cancel(); return }
                self.read(conn, buffer: buf)
            case .malformed(let status):
                self.send(conn, HTTPResponse(status: status, contentType: "text/plain; charset=utf-8", body: Data("Bad request".utf8)))
            }
        }
    }

    private func send(_ conn: NWConnection, _ res: HTTPResponse) {
        var head = "HTTP/1.1 \(res.status) \(HTTPServer.reason(res.status))\r\n"
        head += "Content-Type: \(res.contentType)\r\n"
        head += "Content-Length: \(res.body.count)\r\n"
        // no-store, not no-cache: this is a live local desk, and a stale stylesheet or
        // module served from the browser's cache after an edit is pure confusion.
        head += "Cache-Control: no-store\r\n"
        head += "Connection: close\r\n\r\n"
        var out = Data(head.utf8)
        out.append(res.body)
        conn.send(content: out, completion: .contentProcessed { _ in conn.cancel() })
    }

    /* ---------------------------------------------------------------- parsing */

    enum ParseResult: Equatable {
        case complete(HTTPRequest)
        case partial
        /// The status to answer with: 400 for nonsense, 413 for too large, 501 for chunked bodies.
        case malformed(Int)

        static func == (a: ParseResult, b: ParseResult) -> Bool {
            switch (a, b) {
            case (.partial, .partial): return true
            case let (.malformed(x), .malformed(y)): return x == y
            case let (.complete(x), .complete(y)): return x.method == y.method && x.target == y.target && x.body == y.body
            default: return false
            }
        }
    }

    private static let headerTerminator = Data("\r\n\r\n".utf8)

    static func parse(_ buffer: Data) -> ParseResult {
        guard let headEnd = buffer.range(of: headerTerminator) else {
            // No end of headers yet. Past the cap there never will be one worth waiting for.
            return buffer.count > maxHeaderBytes ? .malformed(413) : .partial
        }
        guard headEnd.lowerBound - buffer.startIndex <= maxHeaderBytes else { return .malformed(413) }
        guard let head = String(data: buffer[buffer.startIndex..<headEnd.lowerBound], encoding: .utf8) else {
            return .malformed(400)
        }
        let lines = head.components(separatedBy: "\r\n")
        let requestLine = lines[0].split(separator: " ")
        guard requestLine.count >= 2 else { return .malformed(400) }

        var headers: [String: String] = [:]
        for line in lines.dropFirst() {
            guard let colon = line.firstIndex(of: ":") else { continue }
            let name = line[line.startIndex..<colon].lowercased()
            let value = line[line.index(after: colon)...].trimmingCharacters(in: .whitespaces)
            // Two Content-Length lines that disagree are how request smuggling starts.
            if name == "content-length", let seen = headers[name], seen != value { return .malformed(400) }
            headers[name] = value
        }
        // Paper's own page never sends a chunked body, and a parser that does not read
        // one must not guess where the next request starts.
        if headers["transfer-encoding"] != nil { return .malformed(501) }

        var contentLength = 0
        if let raw = headers["content-length"] {
            guard let n = Int(raw), n >= 0 else { return .malformed(400) }
            guard n <= maxBodyBytes else { return .malformed(413) }
            contentLength = n
        }

        let bodyStart = headEnd.upperBound
        let available = buffer.distance(from: bodyStart, to: buffer.endIndex)
        if available < contentLength { return .partial }
        let bodyEnd = buffer.index(bodyStart, offsetBy: contentLength)

        return .complete(HTTPRequest(
            method: String(requestLine[0]).uppercased(),
            target: String(requestLine[1]),
            body: Data(buffer[bodyStart..<bodyEnd]),
            headers: headers
        ))
    }

    private static func reason(_ status: Int) -> String {
        switch status {
        case 200: return "OK"
        case 400: return "Bad Request"
        case 403: return "Forbidden"
        case 404: return "Not Found"
        case 413: return "Content Too Large"
        case 501: return "Not Implemented"
        case 500: return "Internal Server Error"
        case 503: return "Service Unavailable"
        default: return "OK"
        }
    }
}
