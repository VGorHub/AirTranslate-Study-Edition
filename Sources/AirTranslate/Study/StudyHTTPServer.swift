import Foundation
import Hummingbird

struct StudyHTTPServer: Sendable {
    enum CaptureAction: String, Sendable { case start, stop, pause, resume }

    let port: Int
    let backend: StudyBackend
    let control: @MainActor @Sendable (CaptureAction) -> Bool
    private let token = UUID().uuidString

    func run() async throws {
        let router = Router()
        router.middlewares.add(StudyHTTPAccess(authority: "127.0.0.1:\(port)"))
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

private struct StudyHTTPAccess: RouterMiddleware {
    static let controlToken = HTTPFields.Element.Name("X-AirTranslate-Token")!
    static let lastEventID = HTTPFields.Element.Name("Last-Event-ID")!
    private static let fetchSite = HTTPFields.Element.Name("Sec-Fetch-Site")!
    let authority: String

    func handle(_ request: Request, context: BasicRequestContext,
                next: (Request, BasicRequestContext) async throws -> Response) async throws -> Response {
        // Exact authority and origin checks also block DNS rebinding and requests from different loopback ports.
        guard request.head.authority == authority,
              request.headers[.origin].map({ $0 == "http://\(authority)" }) ?? true,
              request.headers[Self.fetchSite].map({ $0 == "same-origin" || $0 == "none" }) ?? true else {
            return Response(status: .forbidden)
        }
        var response = try await next(request, context)
        response.headers[.cacheControl] = "no-store"
        response.headers[.contentSecurityPolicy] = "default-src 'none'; frame-ancestors 'none'"
        response.headers[.xContentTypeOptions] = "nosniff"
        return response
    }
}
