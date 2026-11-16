import Foundation
import Hummingbird

struct StudyHTTPServer: Sendable {
    enum CaptureAction: String, Sendable { case start, stop, pause, resume }

    static var configuredPort: Int {
        let configured = ProcessInfo.processInfo.environment["AIRTRANSLATE_STUDY_PORT"].flatMap(Int.init)
            ?? UserDefaults.standard.integer(forKey: "StudyPort")
        return (1...65535).contains(configured) ? configured : 8765
    }

    let port: Int
    let backend: StudyBackend
    let control: @MainActor @Sendable (CaptureAction) -> Bool
    private let token = UUID().uuidString

    func run() async throws {
        let router = Router()
        router.middlewares.add(StudyHTTPAccess(authority: "127.0.0.1:\(port)"))
        let web = StudyWebResources(directory: Bundle.main.resourceURL?.appending(path: "StudyWeb"))
        router.get("/") { _, _ in web.index() }
        router.get("assets/:name") { _, context in
            guard let name = context.parameters.get("name") else { throw HTTPError(.notFound) }
            return try web.asset(String(name))
        }
        let api = router.group("/api/v1")

        api.get("status") { _, _ in
            try json(await backend.status())
        }
        api.get("control-token") { _, _ in
            try json(["token": token])
        }
        api.post("capture/:action") { request, context in
            guard request.headers[.origin] == "http://127.0.0.1:\(port)",
                  request.headers[StudyHTTPAccess.controlToken] == token else {
                throw HTTPError(.forbidden)
            }
            guard let name = context.parameters.get("action"),
                  let action = CaptureAction(rawValue: String(name)) else { throw HTTPError(.notFound) }
            guard await control(action) else { throw HTTPError(.conflict) }
            return Response(status: .accepted)
        }
        api.get("sessions") { request, _ in
            let offset = try integer(request.uri.queryParameters["offset"], default: 0, valid: 0...Int(Int32.max))
            let limit = try integer(request.uri.queryParameters["limit"], default: 50, valid: 1...100)
            do {
                return try json(await backend.sessions(offset: offset, limit: limit))
            } catch {
                throw HTTPError(.serviceUnavailable)
            }
        }
        api.get("sessions/:id/segments") { request, context in
            guard let value = context.parameters.get("id"), let id = UUID(uuidString: String(value)) else {
                throw HTTPError(.badRequest)
            }
            let after = try integer(request.uri.queryParameters["after"], default: 0, valid: 0...Int(Int32.max))
            let limit = try integer(request.uri.queryParameters["limit"], default: 200, valid: 1...500)
            let page: StudySegmentPage?
            do {
                page = try await backend.segments(id: id, after: after, limit: limit)
            } catch {
                throw HTTPError(.serviceUnavailable)
            }
            guard let page else { throw HTTPError(.notFound) }
            return try json(page)
        }
        api.get("events") { request, _ in
            let value = request.headers[StudyHTTPAccess.lastEventID] ?? request.uri.queryParameters["after"].map(String.init)
            let cursor = value.flatMap(StudyCursor.init(value:))
            guard let (id, stream) = await backend.subscribe(after: cursor) else {
                throw HTTPError(.serviceUnavailable)
            }
            return Response(status: .ok, headers: [.contentType: "text/event-stream; charset=utf-8"],
                            body: ResponseBody { writer in
                defer { Task { await backend.unsubscribe(id) } }
                let encoder = makeEncoder()
                try await writer.write(ByteBuffer(string: "retry: 1000\n\n"))
                for await frame in stream {
                    if let frame {
                        let payload = String(decoding: try encoder.encode(frame.event), as: UTF8.self)
                        let event = "id: \(frame.event.cursor)\nevent: \(frame.kind.rawValue)\ndata: \(payload)\n\n"
                        try await writer.write(ByteBuffer(string: event))
                    } else {
                        try await writer.write(ByteBuffer(string: ": keep-alive\n\n"))
                    }
                }
                try await writer.finish(nil)
            })
        }
        let application = Application(router: router, configuration: .init(address: .hostname("127.0.0.1", port: port)))
        try await application.run()
    }

    private func integer<S: StringProtocol>(_ value: S?, default fallback: Int, valid: ClosedRange<Int>) throws -> Int {
        guard let value else { return fallback }
        guard let number = Int(value), valid.contains(number) else { throw HTTPError(.badRequest) }
        return number
    }

    private func json(_ value: some Encodable) throws -> Response {
        let data = try makeEncoder().encode(value)
        return Response(status: .ok, headers: [.contentType: "application/json; charset=utf-8"],
                        body: .init(byteBuffer: ByteBuffer(bytes: data)))
    }

    private func makeEncoder() -> JSONEncoder {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        return encoder
    }
}

private struct StudyWebResources: Sendable {
    let directory: URL?

    func index() -> Response {
        guard let directory,
              let data = try? Data(contentsOf: directory.appending(path: "index.html")) else {
            return Response(status: .serviceUnavailable, headers: [.contentType: "text/plain; charset=utf-8"],
                            body: .init(byteBuffer: ByteBuffer(string: "Build AirTranslate with script/build_and_run.sh to include Study Web.")))
        }
        // Yomitan loads its dictionary popup as an iframe from the Chrome Web Store extension.
        let policy = "default-src 'none'; frame-ancestors 'none'; base-uri 'none'; form-action 'none'; script-src 'self'; style-src 'self'; font-src 'self'; connect-src 'self'; frame-src chrome-extension://likgccmbimhjbgkjambclfkhldnlhbnn/popup.html"
        return Response(status: .ok, headers: [.contentType: "text/html; charset=utf-8", .contentSecurityPolicy: policy],
                        body: .init(byteBuffer: ByteBuffer(bytes: data)))
    }

    func asset(_ name: String) throws -> Response {
        guard let directory, !name.hasPrefix("."),
              name.utf8.allSatisfy({ (45...46).contains($0) || (48...57).contains($0) ||
                  (65...90).contains($0) || $0 == 95 || (97...122).contains($0) }) else { throw HTTPError(.notFound) }
        let file = directory.appending(path: "assets", directoryHint: .isDirectory).appending(path: name)
        let type: String
        switch file.pathExtension {
        case "js": type = "text/javascript; charset=utf-8"
        case "css": type = "text/css; charset=utf-8"
        case "woff2": type = "font/woff2"
        case "woff": type = "font/woff"
        default: throw HTTPError(.notFound)
        }
        guard let values = try? file.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey]),
              values.isRegularFile == true, values.isSymbolicLink == false,
              let data = try? Data(contentsOf: file) else { throw HTTPError(.notFound) }
        return Response(status: .ok, headers: [.contentType: type], body: .init(byteBuffer: ByteBuffer(bytes: data)))
    }
}

private struct StudyHTTPAccess: RouterMiddleware {
    static let controlToken = HTTPFields.Element.Name("X-AirTranslate-Token")!
    static let lastEventID = HTTPFields.Element.Name("Last-Event-ID")!
    private static let fetchSite = HTTPFields.Element.Name("Sec-Fetch-Site")!
    private static let fetchMode = HTTPFields.Element.Name("Sec-Fetch-Mode")!
    private static let fetchDestination = HTTPFields.Element.Name("Sec-Fetch-Dest")!
    let authority: String

    func handle(_ request: Request, context: BasicRequestContext,
                next: (Request, BasicRequestContext) async throws -> Response) async throws -> Response {
        // A link from another site can open the landing page in its own tab. API and asset requests remain same-origin.
        let openingWeb = request.method == .get && request.uri.path == "/" &&
            request.headers[Self.fetchMode] == "navigate" && request.headers[Self.fetchDestination] == "document"
        guard request.head.authority == authority,
              request.headers[.origin].map({ $0 == "http://\(authority)" }) ?? true,
              openingWeb || (request.headers[Self.fetchSite].map({ $0 == "same-origin" || $0 == "none" }) ?? true) else {
            return Response(status: .forbidden)
        }
        var response = try await next(request, context)
        response.headers[.cacheControl] = "no-store"
        if response.headers[.contentSecurityPolicy] == nil {
            response.headers[.contentSecurityPolicy] = "default-src 'none'; frame-ancestors 'none'"
        }
        response.headers[.xContentTypeOptions] = "nosniff"
        return response
    }
}
